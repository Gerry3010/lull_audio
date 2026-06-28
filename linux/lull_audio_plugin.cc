#include "include/lull_audio/lull_audio_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gio/gio.h>
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

  // Now-Playing metadata (published via MPRIS).
  gchar* np_title;
  gchar* np_artist;
  gchar* np_art_url;
  gint64 np_length_us;

  // MPRIS (D-Bus) state.
  guint mpris_owner_id;
  GDBusConnection* mpris_conn;
  guint mpris_root_reg;
  guint mpris_player_reg;
  gboolean mpris_playing;
  gint64 mpris_position_us;
};

G_DEFINE_TYPE(LullAudioPlugin, lull_audio_plugin, g_object_get_type())

// Forward declarations (MPRIS layer is defined further down).
static void mpris_emit_changed(LullAudioPlugin* self);
static void mpris_setup(LullAudioPlugin* self);

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

  // Keep MPRIS in sync: position is read on demand; emit on play/pause change.
  self->mpris_position_us = pos_ns >= 0 ? pos_ns / 1000 : 0;
  gboolean playing = (state == GST_STATE_PLAYING);
  if (playing != self->mpris_playing) {
    self->mpris_playing = playing;
    mpris_emit_changed(self);
  }

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

// Forwards a system transport command (e.g. from MPRIS) to the Dart
// commandStream. [position_ms] >= 0 only for seek.
static void send_command_event(LullAudioPlugin* self, const gchar* command,
                               gint64 position_ms) {
  if (!self->listening || self->event_channel == nullptr) return;
  g_autoptr(FlValue) map = fl_value_new_map();
  fl_value_set_string_take(map, "type", fl_value_new_string("command"));
  fl_value_set_string_take(map, "command", fl_value_new_string(command));
  if (position_ms >= 0) {
    fl_value_set_string_take(map, "positionMs", fl_value_new_int(position_ms));
  }
  fl_event_channel_send(self->event_channel, map, nullptr, nullptr);
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

// ─── MPRIS (org.mpris.MediaPlayer2, D-Bus session bus) ───────────────────────

static const char kMprisXml[] =
    "<node>"
    "  <interface name='org.mpris.MediaPlayer2'>"
    "    <method name='Raise'/>"
    "    <method name='Quit'/>"
    "    <property name='CanQuit' type='b' access='read'/>"
    "    <property name='CanRaise' type='b' access='read'/>"
    "    <property name='HasTrackList' type='b' access='read'/>"
    "    <property name='Identity' type='s' access='read'/>"
    "    <property name='SupportedUriSchemes' type='as' access='read'/>"
    "    <property name='SupportedMimeTypes' type='as' access='read'/>"
    "  </interface>"
    "  <interface name='org.mpris.MediaPlayer2.Player'>"
    "    <method name='Play'/>"
    "    <method name='Pause'/>"
    "    <method name='PlayPause'/>"
    "    <method name='Stop'/>"
    "    <method name='Next'/>"
    "    <method name='Previous'/>"
    "    <method name='Seek'><arg name='Offset' type='x' direction='in'/></method>"
    "    <method name='SetPosition'><arg name='TrackId' type='o' direction='in'/>"
    "      <arg name='Position' type='x' direction='in'/></method>"
    "    <property name='PlaybackStatus' type='s' access='read'/>"
    "    <property name='Metadata' type='a{sv}' access='read'/>"
    "    <property name='Position' type='x' access='read'/>"
    "    <property name='Rate' type='d' access='read'/>"
    "    <property name='MinimumRate' type='d' access='read'/>"
    "    <property name='MaximumRate' type='d' access='read'/>"
    "    <property name='Volume' type='d' access='readwrite'/>"
    "    <property name='CanGoNext' type='b' access='read'/>"
    "    <property name='CanGoPrevious' type='b' access='read'/>"
    "    <property name='CanPlay' type='b' access='read'/>"
    "    <property name='CanPause' type='b' access='read'/>"
    "    <property name='CanSeek' type='b' access='read'/>"
    "    <property name='CanControl' type='b' access='read'/>"
    "  </interface>"
    "</node>";

static GDBusNodeInfo* g_mpris_node = nullptr;

static GVariant* mpris_metadata(LullAudioPlugin* self) {
  GVariantBuilder b;
  g_variant_builder_init(&b, G_VARIANT_TYPE("a{sv}"));
  g_variant_builder_add(
      &b, "{sv}", "mpris:trackid",
      g_variant_new_object_path("/net/geraldhofbauer/lull_audio/track0"));
  if (self->np_length_us > 0) {
    g_variant_builder_add(&b, "{sv}", "mpris:length",
                          g_variant_new_int64(self->np_length_us));
  }
  g_variant_builder_add(
      &b, "{sv}", "xesam:title",
      g_variant_new_string(self->np_title ? self->np_title : "Unknown"));
  if (self->np_artist != nullptr) {
    const gchar* arr[] = {self->np_artist, nullptr};
    g_variant_builder_add(&b, "{sv}", "xesam:artist",
                          g_variant_new_strv(arr, -1));
  }
  if (self->np_art_url != nullptr) {
    g_variant_builder_add(&b, "{sv}", "mpris:artUrl",
                          g_variant_new_string(self->np_art_url));
  }
  return g_variant_builder_end(&b);
}

static const char* mpris_status(LullAudioPlugin* self) {
  return self->mpris_playing ? "Playing"
                             : (self->has_uri ? "Paused" : "Stopped");
}

static void mpris_emit_changed(LullAudioPlugin* self) {
  if (self->mpris_conn == nullptr) return;
  GVariantBuilder props;
  g_variant_builder_init(&props, G_VARIANT_TYPE("a{sv}"));
  g_variant_builder_add(&props, "{sv}", "PlaybackStatus",
                        g_variant_new_string(mpris_status(self)));
  g_variant_builder_add(&props, "{sv}", "Metadata", mpris_metadata(self));
  const gchar* empty[] = {nullptr};
  g_dbus_connection_emit_signal(
      self->mpris_conn, nullptr, "/org/mpris/MediaPlayer2",
      "org.freedesktop.DBus.Properties", "PropertiesChanged",
      g_variant_new("(s@a{sv}@as)", "org.mpris.MediaPlayer2.Player",
                    g_variant_builder_end(&props),
                    g_variant_new_strv(empty, -1)),
      nullptr);
}

static void mpris_root_method(GDBusConnection*, const gchar*, const gchar*,
                              const gchar*, const gchar*, GVariant*,
                              GDBusMethodInvocation* inv, gpointer) {
  g_dbus_method_invocation_return_value(inv, nullptr);  // Raise/Quit: no-op
}

static GVariant* mpris_root_get(GDBusConnection*, const gchar*, const gchar*,
                                const gchar*, const gchar* prop, GError**,
                                gpointer) {
  if (!strcmp(prop, "Identity")) return g_variant_new_string("lull_audio");
  if (!strcmp(prop, "CanQuit")) return g_variant_new_boolean(FALSE);
  if (!strcmp(prop, "CanRaise")) return g_variant_new_boolean(FALSE);
  if (!strcmp(prop, "HasTrackList")) return g_variant_new_boolean(FALSE);
  if (!strcmp(prop, "SupportedUriSchemes") ||
      !strcmp(prop, "SupportedMimeTypes")) {
    const gchar* empty[] = {nullptr};
    return g_variant_new_strv(empty, -1);
  }
  return nullptr;
}

static void mpris_player_method(GDBusConnection*, const gchar*, const gchar*,
                                const gchar*, const gchar* method,
                                GVariant* params, GDBusMethodInvocation* inv,
                                gpointer user_data) {
  LullAudioPlugin* self = LULL_AUDIO_PLUGIN(user_data);
  if (!strcmp(method, "Play")) {
    send_command_event(self, "play", -1);
  } else if (!strcmp(method, "Pause")) {
    send_command_event(self, "pause", -1);
  } else if (!strcmp(method, "Stop")) {
    send_command_event(self, "stop", -1);
  } else if (!strcmp(method, "Next")) {
    send_command_event(self, "next", -1);
  } else if (!strcmp(method, "Previous")) {
    send_command_event(self, "previous", -1);
  } else if (!strcmp(method, "PlayPause")) {
    send_command_event(self, self->mpris_playing ? "pause" : "play", -1);
  } else if (!strcmp(method, "Seek")) {
    gint64 offset_us = 0;
    g_variant_get(params, "(x)", &offset_us);
    gint64 target_ms = (self->mpris_position_us + offset_us) / 1000;
    send_command_event(self, "seek", target_ms < 0 ? 0 : target_ms);
  } else if (!strcmp(method, "SetPosition")) {
    const gchar* path = nullptr;
    gint64 pos_us = 0;
    g_variant_get(params, "(&ox)", &path, &pos_us);
    send_command_event(self, "seek", pos_us / 1000);
  }
  g_dbus_method_invocation_return_value(inv, nullptr);
}

static GVariant* mpris_player_get(GDBusConnection*, const gchar*, const gchar*,
                                  const gchar*, const gchar* prop, GError**,
                                  gpointer user_data) {
  LullAudioPlugin* self = LULL_AUDIO_PLUGIN(user_data);
  if (!strcmp(prop, "PlaybackStatus"))
    return g_variant_new_string(mpris_status(self));
  if (!strcmp(prop, "Metadata")) return mpris_metadata(self);
  if (!strcmp(prop, "Position"))
    return g_variant_new_int64(self->mpris_position_us);
  if (!strcmp(prop, "Rate") || !strcmp(prop, "MinimumRate") ||
      !strcmp(prop, "MaximumRate") || !strcmp(prop, "Volume"))
    return g_variant_new_double(1.0);
  if (!strcmp(prop, "CanControl") || !strcmp(prop, "CanPlay") ||
      !strcmp(prop, "CanPause") || !strcmp(prop, "CanSeek") ||
      !strcmp(prop, "CanGoNext") || !strcmp(prop, "CanGoPrevious"))
    return g_variant_new_boolean(TRUE);
  return nullptr;
}

static gboolean mpris_player_set(GDBusConnection*, const gchar*, const gchar*,
                                 const gchar*, const gchar*, GVariant*,
                                 GError**, gpointer) {
  return TRUE;  // accept Volume writes (no-op)
}

static const GDBusInterfaceVTable kRootVtable = {mpris_root_method,
                                                 mpris_root_get, nullptr, {}};
static const GDBusInterfaceVTable kPlayerVtable = {
    mpris_player_method, mpris_player_get, mpris_player_set, {}};

static void mpris_on_bus_acquired(GDBusConnection* conn, const gchar*,
                                  gpointer user_data) {
  LullAudioPlugin* self = LULL_AUDIO_PLUGIN(user_data);
  self->mpris_conn = conn;
  if (g_mpris_node == nullptr) {
    g_mpris_node = g_dbus_node_info_new_for_xml(kMprisXml, nullptr);
  }
  if (g_mpris_node == nullptr) return;
  self->mpris_root_reg = g_dbus_connection_register_object(
      conn, "/org/mpris/MediaPlayer2", g_mpris_node->interfaces[0],
      &kRootVtable, self, nullptr, nullptr);
  self->mpris_player_reg = g_dbus_connection_register_object(
      conn, "/org/mpris/MediaPlayer2", g_mpris_node->interfaces[1],
      &kPlayerVtable, self, nullptr, nullptr);
}

static void mpris_setup(LullAudioPlugin* self) {
  self->mpris_owner_id = g_bus_own_name(
      G_BUS_TYPE_SESSION, "org.mpris.MediaPlayer2.lull_audio",
      G_BUS_NAME_OWNER_FLAGS_NONE, mpris_on_bus_acquired, nullptr, nullptr,
      self, nullptr);
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
    self->mpris_playing = TRUE;
    mpris_emit_changed(self);
    response = ok();
  } else if (strcmp(method, "pause") == 0) {
    gst_element_set_state(self->playbin, GST_STATE_PAUSED);
    self->mpris_playing = FALSE;
    mpris_emit_changed(self);
    response = ok();
  } else if (strcmp(method, "stop") == 0) {
    gst_element_set_state(self->playbin, GST_STATE_READY);
    self->mpris_playing = FALSE;
    mpris_emit_changed(self);
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
    g_clear_pointer(&self->np_art_url, g_free);
    self->np_length_us = 0;
    if (args != nullptr) {
      FlValue* t = fl_value_lookup_string(args, "title");
      FlValue* a = fl_value_lookup_string(args, "artist");
      FlValue* art = fl_value_lookup_string(args, "artworkUri");
      FlValue* dur = fl_value_lookup_string(args, "durationMs");
      if (t != nullptr) self->np_title = g_strdup(fl_value_get_string(t));
      if (a != nullptr) self->np_artist = g_strdup(fl_value_get_string(a));
      if (art != nullptr) self->np_art_url = g_strdup(fl_value_get_string(art));
      if (dur != nullptr) self->np_length_us = fl_value_get_int(dur) * 1000;
    }
    mpris_emit_changed(self);
    response = ok();
  } else if (strcmp(method, "clearNowPlaying") == 0) {
    g_clear_pointer(&self->np_title, g_free);
    g_clear_pointer(&self->np_artist, g_free);
    g_clear_pointer(&self->np_art_url, g_free);
    self->np_length_us = 0;
    mpris_emit_changed(self);
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
  if (self->mpris_player_reg != 0 && self->mpris_conn != nullptr) {
    g_dbus_connection_unregister_object(self->mpris_conn, self->mpris_player_reg);
    self->mpris_player_reg = 0;
  }
  if (self->mpris_root_reg != 0 && self->mpris_conn != nullptr) {
    g_dbus_connection_unregister_object(self->mpris_conn, self->mpris_root_reg);
    self->mpris_root_reg = 0;
  }
  if (self->mpris_owner_id != 0) {
    g_bus_unown_name(self->mpris_owner_id);
    self->mpris_owner_id = 0;
  }
  g_clear_object(&self->event_channel);
  g_clear_pointer(&self->np_title, g_free);
  g_clear_pointer(&self->np_artist, g_free);
  g_clear_pointer(&self->np_art_url, g_free);
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

  mpris_setup(self);

  g_object_unref(self);
}
