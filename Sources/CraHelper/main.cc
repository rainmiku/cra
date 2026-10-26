// Entry point for every Chromium subprocess (renderer, GPU, utility, plugin,
// alerts). Enters the Chromium sandbox, then loads the framework from the
// enclosing Cra.app bundle and hands control to CEF.
#include "include/cef_app.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"

int main(int argc, char* argv[]) {
  // Must run before the framework loads. Applies the seatbelt policy the
  // browser process sends (--seatbelt-client), using libcef_sandbox.dylib from
  // the framework's Libraries directory (shipped with, and matching, the CEF
  // version in vendor/cef).
  CefScopedSandboxContext sandbox_context;
  if (!sandbox_context.Initialize(argc, argv)) {
    return 1;
  }
  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInHelper()) {
    return 1;
  }
  CefMainArgs main_args(argc, argv);
  return CefExecuteProcess(main_args, nullptr, nullptr);
}
