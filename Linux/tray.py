"""StatusNotifierItem integration for desktops with a compatible tray."""

from gi.repository import Gio, GLib, GdkPixbuf


class Tray:
    xml = """<node><interface name="org.kde.StatusNotifierItem">
      <method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
      <method name="SecondaryActivate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
      <method name="ContextMenu"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
      <property name="Category" type="s" access="read"/>
      <property name="Id" type="s" access="read"/>
      <property name="Title" type="s" access="read"/>
      <property name="Status" type="s" access="read"/>
      <property name="IconName" type="s" access="read"/>
      <property name="IconPixmap" type="a(iiay)" access="read"/>
      <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
      <property name="ItemIsMenu" type="b" access="read"/>
    </interface></node>"""

    def __init__(self, window, icon_path):
        self.window = window
        pixmaps = []
        if icon_path.is_file():
            image = GdkPixbuf.Pixbuf.new_from_file_at_scale(str(icon_path), 24, 24, False).add_alpha(False, 0, 0, 0)
            pixels = image.get_pixels()
            data = bytearray()
            for y in range(image.get_height()):
                for x in range(image.get_width()):
                    i = y * image.get_rowstride() + x * 4
                    data.extend((pixels[i + 3], pixels[i], pixels[i + 1], pixels[i + 2]))
            pixmaps = [(image.get_width(), image.get_height(), list(data))]
        self.properties = {
            "Category": GLib.Variant("s", "ApplicationStatus"),
            "Id": GLib.Variant("s", "net.oseanstudio.myDrive"),
            "Title": GLib.Variant("s", "myDrive"),
            "Status": GLib.Variant("s", "Active"),
            "IconName": GLib.Variant("s", "folder-sync-symbolic" if not pixmaps else ""),
            "IconPixmap": GLib.Variant("a(iiay)", pixmaps),
            "ToolTip": GLib.Variant("(sa(iiay)ss)", ("", pixmaps, "myDrive", "Sync, SMB Drives and Send")),
            "ItemIsMenu": GLib.Variant("b", False),
        }
        try:
            connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
            self.interface = Gio.DBusNodeInfo.new_for_xml(self.xml)
            connection.register_object("/StatusNotifierItem", self.interface.interfaces[0], self.activate, self.get_property, None)
            self.watcher = Gio.bus_watch_name_on_connection(connection, "org.kde.StatusNotifierWatcher",
                Gio.BusNameWatcherFlags.NONE, self.register, lambda *_: self.window.set_hide_on_close(False))
        except GLib.Error:
            self.window.set_hide_on_close(False)

    def register(self, connection, name, owner):
        def done(connection, reply):
            try:
                connection.call_finish(reply)
                self.window.set_hide_on_close(True)
            except GLib.Error:
                self.window.set_hide_on_close(False)
        connection.call(name, "/StatusNotifierWatcher", name, "RegisterStatusNotifierItem",
                        GLib.Variant("(s)", ("/StatusNotifierItem",)), None, Gio.DBusCallFlags.NONE, 3000, None, done)

    def get_property(self, connection, sender, path, interface, name):
        return self.properties.get(name)

    def activate(self, connection, sender, path, interface, method, arguments, invocation):
        if self.window.get_visible() and method == "Activate":
            self.window.set_visible(False)
        else:
            self.window.present()
        invocation.return_value(None)
