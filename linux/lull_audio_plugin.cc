#include "include/lull_audio/lull_audio_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <glib/gstdio.h>
#include <gtk/gtk.h>
#include <gst/gst.h>
#include <sys/utsname.h>
#include <unistd.h>

#include <cstring>

#include "lull_audio_plugin_private.h"

#define LULL_AUDIO_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), lull_audio_plugin_get_type(), \
                              LullAudioPlugin))

struct _LullAudioPlugin {
  GObject parent_instance;

  GstElement* playbin;
  guint bus_watch_id;
  guint position_timer_id;

  FlEventChannel* event_channel;
  gboolean listening;

  // Gapless chunk queue: g_strdup'd URIs waiting to play next.
  GQueue* queue;
  // Temp files created for bytes sources; unlinked on dispose.
  GList* temp_files;
  gint current_chunk_index;
  gboolean has_uri;

  // Now-Playing metadata (consumed by the MPRIS layer, added next).
  gchar* np_title;
  gchar* np_artist;
};

G_DEFINE_TYPE(LullAudioPlugin, lull_audio_plugin, g_object_get_type())

// ─── State events ────────────────────────────────────────────────────────────

// Maps the GStreamer state to the Dart LullProcessingState index.
static int processing_state_for(GstState state) {
  switch (state) {
    case GST_STATE_PLAYING:
    case GST_STATE_PAUSED:
      return 3;  // ready
    case GST_STATE_READY:
      return 1;  // loading
    default:
      return 0;  // idle
  }
}

static void send_state_event(LullAudioPlugin* self) {
  if (!self->listening || self->event_channel == nullptr) return;

  gint64 pos_ns = -1, dur_ns = -1;
  gst_element_query_position(self->playbin, GST_FORMAT_TIME, &pos_ns);
  gst_element_query_duration(self->playbin, GST_FORMAT_TIME, &dur_ns);

  GstState state = GST_STATE_NULL;
  gst_element_get_state(self->playbin, &state, nullptr, 0);

  g_autoptr(FlValue) map = fl_value_new_map();
  fl_value_set_string_take(map, "type", fl_value_new_string("state"));
  fl_value_set_string_take(
      map, "positionMs",
      fl_value_new_int(pos_ns >= 0 ? pos_ns / GST_MSECOND : 0));
  if (dur_ns > 0) {
    fl_value_set_string_take(map, "durationMs",
                             fl_value_new_int(dur_ns / GST_MSECOND));
  }
  fl_value_set_string_take(map, "isPlaying",
                           fl_value_new_bool(state == GST_STATE_PLAYING));
  fl_value_set_string_take(map, "processingState",
                           fl_value_new_int(processing_state_for(state)));
  fl_value_set_string_take(map, "currentChunkIndex",
                           fl_value_new_int(self->current_chunk_index));
  fl_event_channel_send(self->event_channel, map, nullptr, nullptr);
}

static void send_completed_event(LullAudioPlugin* self) {
  if (!self->listening || self->event_channel == nullptr) return;
  g_autoptr(FlValue) map = fl_value_new_map();
  fl_value_set_string_take(map, "type", fl_value_new_string("state"));
  fl_value_set_string_take(map, "isPlaying", fl_value_new_bool(FALSE));
  fl_value_set_string_take(map, "processingState", fl_value_new_int(4));  // completed
  fl_event_channel_send(self->event_channel, map, nullptr, nullptr);
}

static gboolean position_tick(gpointer user_data) {
  send_state_event(LULL_AUDIO_PLUGIN(user_data));
  return G_SOURCE_CONTINUE;
}

// ─── GStreamer bus + gapless ─────────────────────────────────────────────────

static gboolean bus_cb(GstBus* /*bus*/, GstMessage* msg, gpointer user_data) {
  LullAudioPlugin* self = LULL_AUDIO_PLUGIN(user_data);
  switch (GST_MESSAGE_TYPE(msg)) {
    case GST_MESSAGE_EOS:
      // Non-empty queues are handled gaplessly in about-to-finish; reaching EOS
      // means nothing more is queued.
      send_completed_event(self);
      break;
    case GST_MESSAGE_ERROR: {
      g_autoptr(GError) err = nullptr;
      gst_message_parse_error(msg, &err, nullptr);
      g_warning("[lull_audio] GStreamer error: %s",
                err ? err->message : "unknown");
      break;
    }
    default:
      break;
  }
  return TRUE;
}

// Emitted on a streaming thread shortly before the current item ends. Setting
// the next URI here gives gapless playback.
static void about_to_finish_cb(GstElement* /*playbin*/, gpointer user_data) {
  LullAudioPlugin* self = LULL_AUDIO_PLUGIN(user_data);
  gchar* next = static_cast<gchar*>(g_queue_pop_head(self->queue));
  if (next != nullptr) {
    g_object_set(self->playbin, "uri", next, nullptr);
    self->current_chunk_index++;
    g_free(next);
  }
}

// ─── Source → URI ────────────────────────────────────────────────────────────

// Best-effort path to the bundled flutter_assets directory next to the exe.
static gchar* flutter_assets_dir() {
  char buf[4096];
  ssize_t n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
  if (n <= 0) return nullptr;
  buf[n] = '\0';
  g_autofree gchar* dir = g_path_get_dirname(buf);
  return g_build_filename(dir, "data", "flutter_assets", nullptr);
}

// Resolves a source map (kind: file|url|asset|bytes) to a playable URI.
// Returns a newly-allocated string the caller must free, or nullptr.
static gchar* uri_from_source(LullAudioPlugin* self, FlValue* args) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  FlValue* kind_v = fl_value_lookup_string(args, "kind");
  if (kind_v == nullptr) return nullptr;
  const gchar* kind = fl_value_get_string(kind_v);

  if (strcmp(kind, "url") == 0) {
    FlValue* v = fl_value_lookup_string(args, "url");
    return v ? g_strdup(fl_value_get_string(v)) : nullptr;
  }
  if (strcmp(kind, "file") == 0) {
    FlValue* v = fl_value_lookup_string(args, "path");
    return v ? g_filename_to_uri(fl_value_get_string(v), nullptr, nullptr)
             : nullptr;
  }
  if (strcmp(kind, "asset") == 0) {
    FlValue* v = fl_value_lookup_string(args, "asset");
    if (v == nullptr) return nullptr;
    g_autofree gchar* base = flutter_assets_dir();
    if (base == nullptr) return nullptr;
    g_autofree gchar* path =
        g_build_filename(base, fl_value_get_string(v), nullptr);
    return g_filename_to_uri(path, nullptr, nullptr);
  }
  if (strcmp(kind, "bytes") == 0) {
    FlValue* v = fl_value_lookup_string(args, "bytes");
    if (v == nullptr || fl_value_get_type(v) != FL_VALUE_TYPE_UINT8_LIST) {
      return nullptr;
    }
    const uint8_t* data = fl_value_get_uint8_list(v);
    size_t len = fl_value_get_length(v);
    g_autofree gchar* tmp_path = nullptr;
    gint fd = g_file_open_tmp("lull_audio_XXXXXX", &tmp_path, nullptr);
    if (fd < 0) return nullptr;
    bool ok = g_file_set_contents(tmp_path, reinterpret_cast<const gchar*>(data),
                                  len, nullptr);
    close(fd);
    if (!ok) return nullptr;
    self->temp_files = g_list_prepend(self->temp_files, g_strdup(tmp_path));
    return g_filename_to_uri(tmp_path, nullptr, nullptr);
  }
  return nullptr;
}

static void load_uri(LullAudioPlugin* self, gchar* uri /* takes ownership */) {
  gst_element_set_state(self->playbin, GST_STATE_READY);
  g_object_set(self->playbin, "uri", uri, nullptr);
  self->has_uri = TRUE;
  g_free(uri);
}

// ─── Method call handling ────────────────────────────────────────────────────

FlMethodResponse* get_platform_version() {
  struct utsname uname_data = {};
  uname(&uname_data);
  g_autofree gchar* version = g_strdup_printf("Linux %s", uname_data.version);
  g_autoptr(FlValue) result = fl_value_new_string(version);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* ok() {
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static void lull_audio_plugin_handle_method_call(LullAudioPlugin* self,
                                                 FlMethodCall* method_call) {
  g_autoptr(FlMethodResponse) response = nullptr;
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  if (strcmp(method, "getPlatformVersion") == 0) {
    response = get_platform_version();
  } else if (strcmp(method, "setSource") == 0) {
    g_queue_clear_full(self->queue, g_free);
    self->current_chunk_index = 0;
    gchar* uri = uri_from_source(self, args);
    if (uri != nullptr) load_uri(self, uri);
    response = ok();
  } else if (strcmp(method, "enqueue") == 0) {
    gchar* uri = uri_from_source(self, args);
    if (uri != nullptr) {
      if (!self->has_uri) {
        load_uri(self, uri);  // nothing playing yet → become the current item
      } else {
        g_queue_push_tail(self->queue, uri);  // gapless via about-to-finish
      }
    }
    response = ok();
  } else if (strcmp(method, "clearQueue") == 0) {
    g_queue_clear_full(self->queue, g_free);
    gst_element_set_state(self->playbin, GST_STATE_NULL);
    self->has_uri = FALSE;
    self->current_chunk_index = 0;
    response = ok();
  } else if (strcmp(method, "play") == 0) {
    gst_element_set_state(self->playbin, GST_STATE_PLAYING);
    response = ok();
  } else if (strcmp(method, "pause") == 0) {
    gst_element_set_state(self->playbin, GST_STATE_PAUSED);
    response = ok();
  } else if (strcmp(method, "stop") == 0) {
    gst_element_set_state(self->playbin, GST_STATE_READY);
    response = ok();
  } else if (strcmp(method, "seek") == 0) {
    FlValue* v = args ? fl_value_lookup_string(args, "positionMs") : nullptr;
    if (v != nullptr) {
      gint64 ns = fl_value_get_int(v) * GST_MSECOND;
      gst_element_seek_simple(
          self->playbin, GST_FORMAT_TIME,
          static_cast<GstSeekFlags>(GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_KEY_UNIT),
          ns);
    }
    response = ok();
  } else if (strcmp(method, "skipToNext") == 0) {
    gchar* next = static_cast<gchar*>(g_queue_pop_head(self->queue));
    if (next != nullptr) {
      self->current_chunk_index++;
      load_uri(self, next);
      gst_element_set_state(self->playbin, GST_STATE_PLAYING);
    }
    response = ok();
  } else if (strcmp(method, "skipToPrevious") == 0) {
    gst_element_seek_simple(self->playbin, GST_FORMAT_TIME,
                            GST_SEEK_FLAG_FLUSH, 0);
    response = ok();
  } else if (strcmp(method, "setNowPlaying") == 0) {
    g_clear_pointer(&self->np_title, g_free);
    g_clear_pointer(&self->np_artist, g_free);
    if (args != nullptr) {
      FlValue* t = fl_value_lookup_string(args, "title");
      FlValue* a = fl_value_lookup_string(args, "artist");
      if (t != nullptr) self->np_title = g_strdup(fl_value_get_string(t));
      if (a != nullptr) self->np_artist = g_strdup(fl_value_get_string(a));
    }
    response = ok();  // MPRIS publish lands in the next step.
  } else if (strcmp(method, "clearNowPlaying") == 0) {
    g_clear_pointer(&self->np_title, g_free);
    g_clear_pointer(&self->np_artist, g_free);
    response = ok();
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

static void method_call_cb(FlMethodChannel* /*channel*/,
                           FlMethodCall* method_call, gpointer user_data) {
  lull_audio_plugin_handle_method_call(LULL_AUDIO_PLUGIN(user_data),
                                       method_call);
}

// ─── Event channel stream handlers ───────────────────────────────────────────

static FlMethodErrorResponse* listen_cb(FlEventChannel* /*channel*/,
                                        FlValue* /*args*/, gpointer user_data) {
  LullAudioPlugin* self = LULL_AUDIO_PLUGIN(user_data);
  self->listening = TRUE;
  if (self->position_timer_id == 0) {
    self->position_timer_id = g_timeout_add(500, position_tick, self);
  }
  return nullptr;
}

static FlMethodErrorResponse* cancel_cb(FlEventChannel* /*channel*/,
                                        FlValue* /*args*/, gpointer user_data) {
  LullAudioPlugin* self = LULL_AUDIO_PLUGIN(user_data);
  self->listening = FALSE;
  if (self->position_timer_id != 0) {
    g_source_remove(self->position_timer_id);
    self->position_timer_id = 0;
  }
  return nullptr;
}

// ─── Lifecycle ───────────────────────────────────────────────────────────────

static void lull_audio_plugin_dispose(GObject* object) {
  LullAudioPlugin* self = LULL_AUDIO_PLUGIN(object);
  if (self->position_timer_id != 0) {
    g_source_remove(self->position_timer_id);
    self->position_timer_id = 0;
  }
  if (self->bus_watch_id != 0) {
    g_source_remove(self->bus_watch_id);
    self->bus_watch_id = 0;
  }
  if (self->playbin != nullptr) {
    gst_element_set_state(self->playbin, GST_STATE_NULL);
    gst_object_unref(self->playbin);
    self->playbin = nullptr;
  }
  if (self->queue != nullptr) {
    g_queue_free_full(self->queue, g_free);
    self->queue = nullptr;
  }
  for (GList* l = self->temp_files; l != nullptr; l = l->next) {
    g_unlink(static_cast<const gchar*>(l->data));
    g_free(l->data);
  }
  g_list_free(self->temp_files);
  self->temp_files = nullptr;
  g_clear_object(&self->event_channel);
  g_clear_pointer(&self->np_title, g_free);
  g_clear_pointer(&self->np_artist, g_free);
  G_OBJECT_CLASS(lull_audio_plugin_parent_class)->dispose(object);
}

static void lull_audio_plugin_class_init(LullAudioPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = lull_audio_plugin_dispose;
}

static void lull_audio_plugin_init(LullAudioPlugin* self) {
  self->queue = g_queue_new();
  self->temp_files = nullptr;
  self->current_chunk_index = 0;
  self->has_uri = FALSE;
  self->listening = FALSE;
}

void lull_audio_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  if (!gst_is_initialized()) gst_init(nullptr, nullptr);

  LullAudioPlugin* self =
      LULL_AUDIO_PLUGIN(g_object_new(lull_audio_plugin_get_type(), nullptr));

  self->playbin = gst_element_factory_make("playbin", "lull_playbin");
  if (self->playbin != nullptr) {
    g_signal_connect(self->playbin, "about-to-finish",
                     G_CALLBACK(about_to_finish_cb), self);
    GstBus* bus = gst_element_get_bus(self->playbin);
    self->bus_watch_id = gst_bus_add_watch(bus, bus_cb, self);
    gst_object_unref(bus);
  }

  FlBinaryMessenger* messenger = fl_plugin_registrar_get_messenger(registrar);
  g_autoptr(FlStandardMethodCodec) mcodec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      messenger, "lull_audio", FL_METHOD_CODEC(mcodec));
  fl_method_channel_set_method_call_handler(
      channel, method_call_cb, g_object_ref(self), g_object_unref);

  g_autoptr(FlStandardMethodCodec) ecodec = fl_standard_method_codec_new();
  self->event_channel = fl_event_channel_new(
      messenger, "lull_audio/events", FL_METHOD_CODEC(ecodec));
  fl_event_channel_set_stream_handlers(self->event_channel, listen_cb,
                                       cancel_cb, g_object_ref(self),
                                       g_object_unref);

  g_object_unref(self);
}
