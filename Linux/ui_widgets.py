from gi.repository import Gtk, Pango


def button(title, action):
    item = Gtk.Button(label=title)
    item.connect("clicked", lambda *_: action())
    return item


def label(value, style=None):
    widget = Gtk.Label(label=value, xalign=0, ellipsize=Pango.EllipsizeMode.END)
    widget.set_tooltip_text(value)
    if style:
        widget.add_css_class(style)
    return widget


def row(title, detail="", *actions):
    container = Gtk.Box(spacing=6, margin_top=5, margin_bottom=5)
    text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, hexpand=True, valign=Gtk.Align.CENTER)
    text.append(label(title, "heading"))
    if detail:
        text.append(label(detail, "dim-label"))
    container.append(text)
    for action in actions:
        container.append(action)
    return container


def clear(box):
    while child := box.get_first_child():
        box.remove(child)


def menu(entries, icon="view-more-symbolic", title="More actions"):
    control = Gtk.MenuButton(icon_name=icon, tooltip_text=title)
    popover = Gtk.Popover()
    items = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
    for title, command in entries:
        def activate(action=command):
            popover.popdown()
            action()
        items.append(button(title, activate))
    popover.set_child(items)
    control.set_popover(popover)
    return control
