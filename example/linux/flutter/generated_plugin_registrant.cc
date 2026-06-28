//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <lull_audio/lull_audio_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) lull_audio_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "LullAudioPlugin");
  lull_audio_plugin_register_with_registrar(lull_audio_registrar);
}
