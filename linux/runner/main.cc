#include "my_application.h"

int main(int argc, char** argv) {
  // GTK 3's Wayland backend aborts on GNOME versions that removed the
  // xsettings "antialiasing" key. Prefer X11 (XWayland), fall back to
  // Wayland. An explicit GDK_BACKEND from the user still wins.
  g_setenv("GDK_BACKEND", "x11,wayland", FALSE);

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
