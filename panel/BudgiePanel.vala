/*
 * BudgiePanel.vala
 * 
 * Copyright 2014 Ikey Doherty <ikey.doherty@gmail.com>
 * 
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 */

/* These exist for theme integration. */
public class PanelToplevel : Gtk.Bin
{

    public PanelToplevel()
    {
    }
}
public class PanelApplet : Gtk.Bin
{
}
public class AppletHolder : Gtk.Bin
{

    public bool gnome_mode { public get; public set ; }

    public AppletHolder()
    {
        gnome_mode = true;
    }

#if HAVE_GTK313
    protected override Gtk.WidgetPath get_path_for_child(Gtk.Widget child)
    {
        Gtk.WidgetPath path = base.get_path_for_child(child);
#else
    protected override weak Gtk.WidgetPath get_path_for_child(Gtk.Widget child)
    {
        unowned Gtk.WidgetPath path = base.get_path_for_child(child);
#endif
        if (gnome_mode) {
            path.iter_set_object_type(0, typeof(PanelToplevel));
            for (int i=0; i<path.length(); i++) {
                if (path.iter_get_object_type(i) == typeof(AppletHolder)) {
                    path.iter_set_object_type(i, typeof(PanelApplet));
                    break;
                }
            }
        }

        return path;
    }
}

namespace Budgie
{

/**
 * Used to track Applets in a sane way
 */
public class AppletInfo : GLib.Object
{

    /** Applet instance */
    public Budgie.Applet applet { public get; private set; }

    /** Known icon name */
    public string icon {  public get; protected set; }

    /** Instance name */
    public string name { public get; protected set; }

    /** Plugin name providing the applet instance */
    public string plugin_name { public get; private set; }

    /** Packing type */
    public Gtk.PackType pack_type { public get ; public set ; }

    /** Whether to place in the status area or not */
    public bool status_area { public get ; public set ; }

    /** Start padding */
    public int pad_start { public get ; public set ; }

    /** End padding */
    public int pad_end { public get ; public set; }

    /** Position (packging index */
    public int position { public get; public set; }

    /**
     * Construct a new AppletInfo. Simply a wrapper around applets
     */
    public AppletInfo(Budgie.Plugin? plugin, Budgie.Applet applet, string name)
    {
        this.applet = applet;
        icon = plugin.plugin_info.get_icon_name();
        this.name = name;
        plugin_name = plugin.plugin_info.get_name();
    }
}

/**
 * Panel Shadow. Very simples.
 */
public class PanelShadow : Gtk.Window
{

    protected Budgie.Panel? panel;
    public static const int SHADOW_SIZE = 4;

    public PanelShadow(Budgie.Panel? panel)
    {
        decorated = false;
        skip_taskbar_hint = true;
        skip_pager_hint = true;
        type_hint = Gdk.WindowTypeHint.DOCK;

        resizable = false;

        this.panel = panel;
    }

    /* The next methods are all designed to force a specific size only! */
    public override void get_preferred_width(out int min, out int natural)
    {
        var width = panel.primary_monitor_rect.width;
        if (panel.position == PanelPosition.LEFT || panel.position == PanelPosition.RIGHT) {
            width = SHADOW_SIZE;
        }
        min = width;
        natural = width;
    }

    public override void get_preferred_height(out int min, out int natural)
    {
        if (panel.position == PanelPosition.LEFT || panel.position == PanelPosition.RIGHT) {
            min = panel.primary_monitor_rect.height;
            natural = min;
        } else {
            min = SHADOW_SIZE;
            natural = SHADOW_SIZE;
        }
    }

    public override void get_preferred_height_for_width(int width, out int min, out int natural)
    {
        if (panel.position == PanelPosition.LEFT || panel.position == PanelPosition.RIGHT) {
            min = screen.get_height();
            natural = min;
        } else {
            min = SHADOW_SIZE;
            natural = SHADOW_SIZE;
        }
    }

    public override void get_preferred_width_for_height(int height, out int min, out int natural)
    {
        var width = panel.primary_monitor_rect.width;
        if (panel.position == PanelPosition.LEFT || panel.position == PanelPosition.RIGHT) {
            width = SHADOW_SIZE;
        }
        min = width;
        natural = width;
    }

    public override bool draw(Cairo.Context ctx)
    {
        var style = get_style_context();
        Gtk.Allocation alloc;

        get_allocation(out alloc);

        style.render_background(ctx, alloc.x, alloc.y, alloc.width, alloc.height);
        style.render_frame(ctx, alloc.x, alloc.y, alloc.width, alloc.height);

        return true;
    }
}

public class Panel : Gtk.Window
{

    protected int intended_height;

    public int panel_size {
        get {
            return intended_height;
        }
        set {
            intended_height = value;
            update_position();
            set_struts();
        }
    }

    public PanelPosition position;
    private Gtk.Box master_layout;
    private Gtk.Box widgets_area;

    Peas.Engine engine;
    Peas.ExtensionSet extset;

    // Right now lock to 4px shadow
    const int SHADOW_SIZE = 4;
    private PanelShadow shadow;

    // Must keep in scope otherwise they garbage collect and die

    /* Global plugin table */
    Gee.HashMap<string,Budgie.Plugin?> plugin_map;
    /* Loaded applet table */
    Gee.HashMap<string,Budgie.AppletInfo?> applets;

    KeyFile config;

    Settings settings;

    // Panel editor/preferences
    private PanelEditor prefs_dialog;

    // Defined at compile time, check panelconfig.h and panelconfig.vapi
    static string module_directory = MODULE_DIRECTORY;
    static string module_data_directory = MODULE_DATA_DIRECTORY;

    public bool gnome_mode { set; get; }
    protected bool use_shadow;

    private int primary_monitor;
    public Gdk.Rectangle primary_monitor_rect;

    private ulong alloc_id;
    public int stored_x;
    public int stored_y;
    public int stored_height;
    public int stored_width;

    protected PanelMover mover;
    /* Whether to draw the borders (i.e. in movement) */
    protected bool draw_border = true;

    protected Gtk.Widget? target_style;

    protected bool hidden_struts = false;

    public Panel()
    {
        primary_monitor = screen.get_primary_monitor();
        
        screen.get_monitor_geometry(primary_monitor, out primary_monitor_rect);
        screen.monitors_changed.connect(on_screen_changed);

        /* Set an RGBA visual whenever we can */
        Gdk.Visual? vis = screen.get_rgba_visual();
        if (vis != null) {
            set_visual(vis);
        } else {
            message("No RGBA visual available");
        }
        app_paintable = true;
        resizable = false;

        // need a shadow. only supports bottom position right now.
        shadow = new PanelShadow(this);
        shadow.set_visual(vis);

        settings = new Settings("com.evolve-os.budgie.panel");
        alloc_id = size_allocate.connect(on_size_allocate);

        on_settings_change("enable-shadow");
        on_settings_change("dark-theme");

        target_style = this;

        /* Ensure to initialise styles */
        try {
#if HAVE_GTK313
            File ruri = File.new_for_uri("resource://com/evolve-os/budgie/panel/style_313.css");
#else
            File ruri = File.new_for_uri("resource://com/evolve-os/budgie/panel/style.css");
#endif
            var prov = new Gtk.CssProvider();
            prov.load_from_file(ruri);
            Gtk.StyleContext.add_provider_for_screen(screen, prov, Gtk.STYLE_PROVIDER_PRIORITY_FALLBACK);

            ruri = File.new_for_uri("resource://com/evolve-os/budgie/panel/app.css");
            prov = new Gtk.CssProvider();
            prov.load_from_file(ruri);
            Gtk.StyleContext.add_provider_for_screen(screen, prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        } catch (Error e) {
            stderr.printf("Unable to load styles: %s\n", e.message);
        }

        // simple layout
        master_layout = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
        add(master_layout);

        set_decorated(false);
        type_hint = Gdk.WindowTypeHint.DOCK;
        set_keep_above(true);

        get_style_context().remove_class("background");

        // Initialize plugins engine
        engine = Peas.Engine.get_default();
        engine.add_search_path(module_directory, module_data_directory);
        // Home directory
        var dirm = "%s/budgie-panel".printf(Environment.get_user_data_dir());
        engine.add_search_path(dirm, null);
        extset = new Peas.ExtensionSet(engine, typeof(Budgie.Plugin));

        plugin_map = new Gee.HashMap<string,Budgie.Plugin?>(null,null,null);
        applets = new Gee.HashMap<string,Budgie.AppletInfo?>(null,null,null);

        // Get an update from GSettings where we should be (position set
        // for error fallback)
        position = PanelPosition.BOTTOM;
        settings.changed.connect(on_settings_change);
        on_settings_change("location");

        // Ensure we dynamically update our size
        settings.bind("size", this, "panel_size", SettingsBindFlags.GET);
        panel_size = settings.get_int("size");

        // where the clock, etc, live
        var widgets_wrap = new Gtk.EventBox();
        widgets_wrap.get_style_context().add_class("message-area");
        widgets_wrap.margin = 3;
        widgets_area = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 5);
        widgets_area.margin = 2;
        widgets_wrap.add(widgets_area);
        widgets_wrap.show_all();
        master_layout.pack_end(widgets_wrap, false, false, 0);
        master_layout.child_set_property(widgets_wrap, "position", 1);

        // Right now our plugins are kinda locked in where they go. Sorry
        extset.extension_added.connect(on_extension_added);


        load_config();

        on_settings_change("gnome-panel-theme-integration");

        // prevent masses of size allocates
        stored_y = stored_width = stored_height = stored_x = 0;
        master_layout.show();
        show();

        // post config/extension loading routine, ensure we dynamically load at runtime
        engine.load_plugin.connect_after((i)=> {
            var ext = extset.get_extension(i);
            on_extension_added(i, ext);
        });

        set_struts();

        // Horrible, but all we can do for now.
        var menu = new Gtk.Menu();
        var item = new Gtk.MenuItem.with_label("Preferences...");
        item.activate.connect(()=> {
            invoke_prefs();
        });
        menu.add(item);
        menu.show_all();

        button_release_event.connect((b)=> {
            if (b.button == 3) {
                menu.popup(null, null, null, b.button, Gdk.CURRENT_TIME);
                return true;
            }
            return false;
        });

        add_events(Gdk.EventMask.ENTER_NOTIFY_MASK | Gdk.EventMask.LEAVE_NOTIFY_MASK |
                   Gdk.EventMask.BUTTON_PRESS_MASK | Gdk.EventMask.BUTTON_RELEASE_MASK);
        mover = new PanelMover(this);
        mover.animation_begin.connect(()=> {
            draw_border = false;
            queue_draw();
            shadow.hide();
        });
        mover.animation_end.connect(()=> {
            draw_border = true;
            queue_draw();
        });
        mover.visibility_changed.connect((b)=> {
            hidden_struts = !b;
            set_struts();
            if (b && use_shadow ) {
                update_position();
            }
        });

        /* First start, hide panel after a second so user actually knows
         * where it is before it disappears.. */
        if (settings.get_string("hide-policy") == "automatic") {
            Timeout.add(1000, ()=> {
                mover.hide();
                return false;
            });
        }
    }

    protected void on_screen_changed()
    {
        screen.get_monitor_geometry(primary_monitor, out primary_monitor_rect);
        stored_x = 0;
        stored_y = 0;
        stored_width = 0;
        stored_height = 0;

        queue_resize();
    }

#if HAVE_GTK313
    protected override Gtk.WidgetPath get_path_for_child(Gtk.Widget child)
    {
        Gtk.WidgetPath path = base.get_path_for_child(child);
#else
    protected override weak Gtk.WidgetPath get_path_for_child(Gtk.Widget child)
    {
        unowned Gtk.WidgetPath path = base.get_path_for_child(child);
#endif
        if (gnome_mode) {
            path.iter_set_object_type(0, typeof(PanelToplevel));
        }

        return path;
    }

    protected void on_size_allocate(Gtk.Allocation alloc)
    {
        // Only update when we *absolutely* need to.
        if (alloc.x == stored_x && alloc.y == stored_y && alloc.width == stored_width && alloc.height == stored_height) {
            return;
        }

        stored_x = alloc.x;
        stored_y = alloc.y;
        stored_width = alloc.width;
        stored_height = alloc.height;

        update_position();
        set_struts();
    }

    protected void on_settings_change(string key)
    {
        if (key == "location") {
            var val = settings.get_string(key);
            switch (val) {
                case "top":
                    position = PanelPosition.TOP;
                    break;
                case "left":
                    position = PanelPosition.LEFT;
                    break;
                case "right":
                    position = PanelPosition.RIGHT;
                    break;
                default:
                    position = PanelPosition.BOTTOM;
                    break;
            }
            update_position();
            set_struts();
        } else if (key == "enable-shadow") {
            use_shadow = settings.get_boolean(key);
            update_position();
            set_struts();
        } else if (key == "gnome-panel-theme-integration") {
            gnome_mode = settings.get_boolean(key);
            update_toplevel_style();
        } else if (key == "dark-theme") {
            this.get_settings().set_property("gtk-application-prefer-dark-theme",
                settings.get_boolean(key));
        }
    }

    /* Taken from config */
    protected void add_applet(ref Budgie.AppletInfo applet_info)
    {
        Gtk.PackType pack = Gtk.PackType.START;
        unowned Gtk.Box? pack_target = master_layout;
        bool center = false;
        int index = 0;
        int pad_start = 0, pad_end = 0;
        string name = applet_info.name;
        unowned Budgie.Applet applet = applet_info.applet;
        AppletHolder? target_widg;

        try {
            if (config.has_key(name, "Pack")) {
                var ptype = config.get_string(name, "Pack").down();
                switch (ptype) {
                    case "end":
                        pack = Gtk.PackType.END;
                        break;
                    /*case "center":
                        center = true;
                        break;*/
                    default:
                        pack = Gtk.PackType.START;
                        break;
                }
            }
            if (config.has_key(name, "PaddingStart")) {
                pad_start = config.get_integer(name, "PaddingStart");
            }
            if (config.has_key(name, "PaddingEnd")) {
                pad_end = config.get_integer(name, "PaddingEnd");
            }
            if (config.has_key(name, "StatusArea")) {
                if (config.get_boolean(name, "StatusArea") == true) {
                    pack_target = widgets_area;
                }
            }
            // Deprecated in 3.12, use margin-start, margin-end in future
            if (position == PanelPosition.TOP || position == PanelPosition.BOTTOM) {
                applet.margin_left = pad_start;
                applet.margin_right = pad_end;
            } else {
                applet.margin_top = pad_start;
                applet.margin_bottom = pad_end;
            }
        } catch (Error e) {
            warning("Plugin load error gaining attributes: %s", e.message);
        }
        inform_size(applet);

        applet.show();

        // Existing themes refer to PanelToplevel and PanelApplet extensively.
        target_widg = new AppletHolder();
        target_widg.gnome_mode = gnome_mode;
        // Ensures we don't get wnck.pager throwing a hissy fit in gnome mode
        target_widg.set_size_request(1, 1);
        (target_widg as AppletHolder).add(applet);
        target_widg.show();

        if (center) {
            // not yet supported as we need checks for 3.2
            /*pack_target.set_center_widget(widget);*/
            pack_target.pack_start(target_widg, false, false, 0);
        } else if (pack == Gtk.PackType.START) {
            pack_target.pack_start(target_widg, false, false, 0);
        } else {
            pack_target.pack_end(target_widg, false, false, 0);
        }

        // We're pretty interested in what happens in the editor..
        applet_info.pack_type = pack;
        applet_info.pad_start = pad_start;
        applet_info.pad_end = pad_end;
        if (pack_target == widgets_area) {
            applet_info.status_area = true;
        }

        foreach (var sprog in pack_target.get_children()) {
            if (sprog is AppletHolder) {
                var sprog2 = (sprog as AppletHolder).get_child() as Budgie.Applet;
                if (sprog2 == applet) {
                    break;
                }
            } else if (sprog == applet) {
                break;
            }
            index++;
        }
        applet_info.position = index;
        applets[name] = applet_info;
        applet_info.notify.connect(applet_updated);

        applet_added(ref applet_info);
    }

    /* Something about the applet was altered */
    public void applet_updated(Object o, ParamSpec p)
    {
        AppletInfo app_info = o as AppletInfo;
        Gtk.Widget? target_widg  = app_info.applet.get_parent();
        Gtk.Box owner = target_widg.get_parent() as Gtk.Box;

        if (p.name == "pad-start") {
            if (position == PanelPosition.TOP || position == PanelPosition.BOTTOM) {
                app_info.applet.margin_left = app_info.pad_start;
            } else {
                app_info.applet.margin_top = app_info.pad_start;
            }
        }
        if (p.name == "pad-end") {
            if (position == PanelPosition.TOP || position == PanelPosition.BOTTOM) {
                app_info.applet.margin_right = app_info.pad_end;
            } else {
                app_info.applet.margin_bottom = app_info.pad_end;
            }
        }
        if (p.name == "position") {
            /* This is where it gets complicated.. */
            if (app_info.position < 0) {
                app_info.position = 0;
                return;
            }
            if (app_info.position > owner.get_children().length()-1) {
                app_info.position = (int)owner.get_children().length()-1;
                return;
            }
            owner.reorder_child(target_widg, app_info.position);
        }
        if (p.name == "pack-type") {
            owner.child_set_property(target_widg, "pack-type", app_info.pack_type);
        }
        if (p.name == "status-area") {
            // actually need to remove the child from area its in and reparent it.
            Gtk.Box? new_owner;
            if (owner == master_layout) {
                new_owner = widgets_area;
            } else {
                new_owner = master_layout;
            }

            owner.remove(target_widg);
            new_owner.pack_start(target_widg, false, false, 0);
            // Always goes to being a pack start, i.e. at the end of the current items
            app_info.pack_type = Gtk.PackType.START;
            app_info.position = (int)new_owner.get_children().length();
        }
        inform_size(app_info.applet);
        update_config();
    }

    /* Add a new applet dynamically
     */
    public void add_new_applet(string id)
    {
        // Ensure unique name
        string name = id;
        string base_name = name;
        uint suffix = 1;
        while (true) {
            if (config.has_group(name)) {
                suffix += 1;
                name = "%s-%u".printf(base_name, suffix);
            } else {
                break;
            }
        }

        string[] children = config.get_string_list("Panel", "Children");
        children += name;
        config.set_string(name, "ID", id);
        config.set_string_list("Panel", "Children", children);
        load_applet(name);
        update_config();
    }

    /* Remove applet. Also somewhat dynamically
     */
    public void remove_applet(string name)
    {
        AppletInfo appl = applets[name];
        // So we can actually reposition everyone
        Gtk.Widget? target_widg = appl.applet.get_parent();
        Gtk.Box? owner = target_widg.get_parent() as Gtk.Box;
        int position = appl.position;

        applet_removed(name);
        /* Send a destroy */
        appl.applet.destroy();

        /* Unfortunately this is ugly as all shit, but what can ya do. */
        uint length = owner.get_children().length();
        foreach (var applet in applets.values) {
            Gtk.Widget? target2 = applet.applet.get_parent();
            if (target2.get_parent() == owner && applet.position > position) {
                applet.position -= 1;
            }
            if (applet.position < 0) {
                applet.position = 0;
            }
        }
        appl = null;
        applets.unset(name);
        update_config();
    }

    public int compare_applet(Budgie.AppletInfo? A, Budgie.AppletInfo? B)
    {
            return (int) (A.position > B.position) - (int) (A.position < B.position);
    }

    /* Update our config */
    protected void update_config()
    {
        KeyFile outconfig = new KeyFile();
        var apls = new Gee.ArrayList<AppletInfo?>();
        var stpls = new Gee.ArrayList<AppletInfo?>();

        foreach (var applet in applets.values) {
            if (applet.status_area) {
                stpls.add(applet);
            } else {
                apls.add(applet);
            }
        }

        apls.sort(compare_applet);
        stpls.sort(compare_applet);

        // Begin writing our config.
        string[] children = {};
        foreach (var a in apls) {
            children += a.name;
        }
        foreach (var a in stpls) {
            children += a.name;
        }

        outconfig.set_string_list("Panel", "Children", children);
        // And now basically write off each applet info
        foreach (var a in children) {
            var applet = applets[a];
            outconfig.set_string(a, "ID", applet.plugin_name);
            if (applet.pack_type != Gtk.PackType.START) {
                string pck_string = applet.pack_type == Gtk.PackType.START ? "start" : "end";
                outconfig.set_string(a, "Pack", pck_string);
            }
            if (applet.pad_start > 0) {
                outconfig.set_integer(a, "PaddingStart", applet.pad_start);
            }
            if (applet.pad_end > 0) {
                outconfig.set_integer(a, "PaddingEnd", applet.pad_end);
            }
            if (applet.status_area) {
                outconfig.set_boolean(a, "StatusArea", applet.status_area);
            }
        }
        string output_conf = outconfig.to_data();

        string configdir = Environment.get_user_config_dir();
        string path = @"$configdir/budgie.ini";
        try {
            FileUtils.set_contents(path, output_conf);
        } catch (Error e) {
            warning("Unable to save Budgie config: %s", e.message);
        }

        config = (owned)outconfig;
    }

    /* Load an applet */
    protected void load_applet(string name)
    {
        /* Determine if the plugin is loaded yet. */
        string? plug = null;

        if (applets.has_key(name)) {
            return;
        }

        try {
            plug = config.get_string(name, "ID");
            // Found the correct plugin handler, we can go handle this.
            if (plugin_map.has_key(plug)) {
                var applet = plugin_map[plug].get_panel_widget();
                var ainfo = new AppletInfo(plugin_map[plug], applet, name);
                add_applet(ref ainfo);
                return;
            }
        } catch (Error e) {
            warning("Error loading %s: %s", name, e.message);
            return;
        }

        // Got this far we actually need to load the underlying plugin
        unowned Peas.PluginInfo? plugin = null;

        foreach(var plugini in engine.get_plugin_list()) {
            if (plugini.get_name() == plug) {
                plugin = plugini;
                break;
            }
        }
        if (plugin == null) {
            warning("Could not find plugin: %s", plug);
            return;
        }
        engine.try_load_plugin(plugin);
    }

    /**
     * Handle post-plugin-load. Try to add pending applets if required.
     */
    protected void on_extension_added(Peas.PluginInfo i, Object p)
    {
        var plugin = p as Budgie.Plugin;
        plugin_map[i.get_name()] = plugin;
        string[] children;

        try {
            children = config.get_string_list("Panel", "Children");
        } catch (Error e) {
            message("Panel config specifies no children!");
            return;
        }

        // Iterate the children, and then load them into the panel
        foreach (var child in children) {
            child = child.strip();
            try {
                var plug = config.get_string(child, "ID");
                if (plug == i.get_name()) {
                    /* Try to add an applet for this one, first time this plugin
                     * has loaded */
                    if (!applets.has_key(child)) {
                        var applet = plugin.get_panel_widget();
                        var ainfo = new AppletInfo(plugin, applet, child);
                        add_applet(ref ainfo);
                    }
                }
            } catch (Error e) {
                warning("Applet initialisation issue: %s", e.message);
            }
        }
    }

    /*
     * Load config for our applets
     */
    protected void load_config()
    {
        string[] children;
        bool user_config = false;

        string configdir = Environment.get_user_config_dir();
        string path = @"$configdir/budgie.ini";

        config = new GLib.KeyFile();
        try {
            config.load_from_file(path, KeyFileFlags.KEEP_COMMENTS);
            user_config = true;
        } catch (Error e) {
            message("Unable to find user config: %s", e.message);
        }

        if (!user_config) {
            // Load in the default panel configuration
            path = @"$DATADIR/layout.ini";
            try {
                config.load_from_file(path, KeyFileFlags.KEEP_COMMENTS);
            } catch (Error e) {
                critical("Unable to find default config %s: %s", path, e.message);
                return;
            }
        }

        // Get the children that should be here
        try {
            children = config.get_string_list("Panel", "Children");
        } catch (Error e) {
            message("Panel config specifies no children!");
            return;
        }

        // Iterate the children, and then load them into the panel
        foreach (var child in children) {
            child = child.strip();

            if (!config.has_group(child)) {
                warning("%s not found", child);
                continue;
            }
            load_applet(child);
        }
    }

    /* Struts on X11 are used to reserve screen-estate, i.e. for guys like us.
     * woo.
     */
    protected void set_struts()
    {
        Gdk.Atom atom;
        long struts[12];
        /*
        strut-left strut-right strut-top strut-bottom
        strut-left-start-y   strut-left-end-y
        strut-right-start-y  strut-right-end-y
        strut-top-start-x    strut-top-end-x
        strut-bottom-start-x strut-bottom-end-x
        */

        if (!get_realized()) {
            return;
        }

        long panel_size = intended_height;

        if (hidden_struts) {
            panel_size = 1;
        }

        // Struts dependent on position
        switch (position) {
            case PanelPosition.TOP:
                struts = { 0, 0, primary_monitor_rect.y+panel_size, 0,
                    0, 0, 0, 0,
                    primary_monitor_rect.x, primary_monitor_rect.x+primary_monitor_rect.width,
                    0, 0
                };
                break;
            case PanelPosition.LEFT:
                struts = { panel_size, 0, 0, 0,
                    primary_monitor_rect.y, primary_monitor_rect.y+primary_monitor_rect.height, 
                    0, 0, 0, 0, 0, 0
                };
                break;
            case PanelPosition.RIGHT:
                struts = { 0, panel_size, 0, 0,
                    0, 0,
                    primary_monitor_rect.y, primary_monitor_rect.y+primary_monitor_rect.height,
                    0, 0, 0, 0
                };
                break;
            case PanelPosition.BOTTOM:
            default:
                struts = { 0, 0, 0, 
                    (screen.get_height()-primary_monitor_rect.height-primary_monitor_rect.y) + panel_size,
                    0, 0, 0, 0, 0, 0, 
                    primary_monitor_rect.x, primary_monitor_rect.x + primary_monitor_rect.width
                };
                break;
        }

        // all relevant WMs support this, Mutter included
        atom = Gdk.Atom.intern("_NET_WM_STRUT_PARTIAL", false);
        Gdk.property_change(get_window(), atom, Gdk.Atom.intern("CARDINAL", false),
            32, Gdk.PropMode.REPLACE, (uint8[])struts, 12);
    }

    protected void update_position()
    {
        int height = get_allocated_height();
        int width = get_allocated_width();
        int x = 0, y = 0;
        int pan_x = 0, pan_y = 0;

        string[] classes =  {
            "top",
            "bottom",
            "left",
            "right"
        };
        string newclass;
        switch (position) {
            case PanelPosition.TOP:
                newclass = "top";
                y = primary_monitor_rect.y+0;
                pan_y = intended_height;
                break;
            case PanelPosition.LEFT:
                newclass = "left";
                y = primary_monitor_rect.y+0;
                pan_x = width;
                break;
            case PanelPosition.RIGHT:
                newclass = "right";
                x = primary_monitor_rect.x+primary_monitor_rect.width-width;
                pan_x = x - SHADOW_SIZE;
                break;
            case PanelPosition.BOTTOM:
            default:
                newclass = "bottom";
                y = primary_monitor_rect.y+primary_monitor_rect.height-height;
                pan_y = y - SHADOW_SIZE;
                break;
        }
        var st = get_style_context();
        var st2 = shadow.get_style_context();
        foreach (var tclass in classes) {
            if (newclass != tclass) {
                st.remove_class(tclass);
                st2.remove_class(tclass);
            }
        }
        if (newclass != "") {
            st.add_class(newclass);
            st2.add_class(newclass);
        }

        Gtk.Orientation orientation;

        if (position == PanelPosition.LEFT || position == PanelPosition.RIGHT) {
            // Effectively we're now vertical. deal with it.
            orientation = Gtk.Orientation.VERTICAL;
        } else {
            orientation = Gtk.Orientation.HORIZONTAL;
        }

        if (master_layout is Gtk.Orientable) {
                master_layout.set_orientation(orientation);
        }
        if (widgets_area is Gtk.Orientable) {
                widgets_area.set_orientation(orientation);
        }
        if (applets != null && applets.values != null) {
                foreach (var applet_info in applets.values) {
                    if (applet_info != null) {
                        applet_info.applet.orientation_changed(orientation);
                        applet_info.applet.position_changed(position);
                        inform_size(applet_info.applet);

                        applet_info.applet.freeze_notify();
                        applet_info.applet.set_property("margin", 0);
                        if (position == PanelPosition.TOP || position == PanelPosition.BOTTOM) {
                            applet_info.applet.margin_left = applet_info.pad_start;
                            applet_info.applet.margin_right = applet_info.pad_end;
                        } else {
                            applet_info.applet.margin_top = applet_info.pad_start;
                            applet_info.applet.margin_bottom = applet_info.pad_end;
                        }
                        applet_info.applet.thaw_notify();
                    }
                };
        }

        SignalHandler.block(this, alloc_id);
        move(x,y);
        SignalHandler.unblock(this, alloc_id);

        /* Move shadow too. */
        if (use_shadow) {
            shadow.hide();
            shadow.move(pan_x, pan_y);
            shadow.show();
        } else {
            shadow.hide();
        }

        queue_draw();
    }

    protected void update_toplevel_style()
    {
        if (gnome_mode) {
            if (target_style == this || target_style == null) {
                target_style = new PanelToplevel();
            }
        } else {
            if (target_style != this) {
                target_style.destroy();
            }
            target_style = this;
        }

        // Base styling
        if (gnome_mode) {
            get_style_context().remove_class("budgie-panel");
        } else {
            get_style_context().add_class("budgie-panel");
        }

        foreach(var applet_info in applets.values) {
            var parent = applet_info.applet.get_parent() as AppletHolder;
            parent.gnome_mode = gnome_mode;
        }

        queue_draw();
    }

    /**
     * Ensure our CSS theming is followed. In future we'll enable much more
     * in the way of customisations (background image anyone?)
     */
    public override bool draw(Cairo.Context cr)
    {
        var st = target_style.get_style_context();

        st.render_background(cr, 0, 0, get_allocated_width(), get_allocated_height());
        if (draw_border) {
            st.render_frame(cr, 0, 0, get_allocated_width(), get_allocated_height());
        }

        return base.draw(cr);
    }


    /* The next methods are all designed to force a specific size only! */
    public override void get_preferred_width(out int min, out int natural)
    {
        var width = primary_monitor_rect.width;
        if (position == PanelPosition.LEFT || position == PanelPosition.RIGHT) {
            width = intended_height;
        }
        min = width;
        natural = width;
    }

    public override void get_preferred_height(out int min, out int natural)
    {
        if (position == PanelPosition.LEFT || position == PanelPosition.RIGHT) {
            min = primary_monitor_rect.height;
            natural = min;
        } else {
            min = intended_height;
            natural = intended_height;
        }
    }

    public override void get_preferred_height_for_width(int width, out int min, out int natural)
    {
        if (position == PanelPosition.LEFT || position == PanelPosition.RIGHT) {
            min = screen.get_height();
            natural = min;
        } else {
            min = intended_height;
            natural = intended_height;
        }
    }

    public override void get_preferred_width_for_height(int height, out int min, out int natural)
    {
        var width = primary_monitor_rect.width;
        if (position == PanelPosition.LEFT || position == PanelPosition.RIGHT) {
            width = intended_height;
        }
        min = width;
        natural = width;
    }

    /**
     * Simple action, eventually applets will need to register for this ability, it
     * hooks them up to the panel-main-menu action under Budgie
     * Note it is currently hard-coded for Budgie Menu
     */
    public void invoke_menu()
    {
        foreach(var applet_info in applets.values) {
            if (applet_info != null) {
                applet_info.applet.action_invoked(Budgie.ActionType.INVOKE_MAIN_MENU);
            }
        }
    }

    /** Signals **/
    public signal void applet_added(ref AppletInfo info);
    public signal void applet_removed(string name);

    /**
     * Show our editor/prefs dialog
     */
    public void invoke_prefs()
    {
        if (prefs_dialog != null && prefs_dialog.get_visible()) {
            prefs_dialog.present();
            return;
        }
        if(prefs_dialog != null) {
            prefs_dialog.destroy();
        }

        prefs_dialog = new PanelEditor(this);
        /* We now emit for lazy-sake to populate the prefs dialog */
        foreach (var applet_info in applets.values) {
            applet_added(ref applet_info);
        }

        prefs_dialog.show_all();
        prefs_dialog.present();
    }


    /* Inform a given applet the new maximum icon size */
    protected void inform_size(Applet applet)
    {
        /* Always remove a few pixels because icons are sensitive creatures */
        int offset = 8;
        /* Maximum size */
        int height = intended_height - offset;

        int rem = height % 8;
        int size = height - rem;

        /* Smaller variant  */
        int reduced_height = height - ((int)(height * 0.35));
        int rem2 = reduced_height % 8;
        int smaller = reduced_height - rem2;

        if (size < 16) {
            size = 16;
        }
        if (smaller < 16) {
            smaller = 16;
        }

        applet.icon_size_changed((uint)size, (uint)smaller);
    }

} // End Panel class

class PanelMain : GLib.Application
{

    static Budgie.Panel? panel = null;
    private static bool invoke_menu = false;
    private static bool invoke_prefs = false;

	private const GLib.OptionEntry[] options = {
        { "menu", 0, 0, OptionArg.NONE, ref invoke_menu, "Invoke the panel menu", null },
        { "prefs", 0, 0, OptionArg.NONE, ref invoke_prefs, "Invoke the panel preferences", null },
        { null }
    };

    public override void activate()
    {
        hold();
        if (panel == null) {
            panel = new Budgie.Panel();
            Gtk.main();
        }
        release();
    }

    private PanelMain()
    {
        Object (application_id: "com.evolve_os.BudgiePanel", flags: 0);
        /* Set up our options, currently only "menu" */
        var action = new SimpleAction("menu", null);
        action.activate.connect(()=> {
            hold();
            // Only on valid panel instances
            if (panel != null) {
                panel.invoke_menu();
            }
            release();
        });
        add_action(action);

        action = new SimpleAction("prefs", null);
        action.activate.connect(()=> {
            hold();
            // Again, only on valid instances
            if (panel != null) {
                panel.invoke_prefs();
            }
            release();
        });
        add_action(action);
    }
    /**
     * Main entry
     */

    public static int main(string[] args)
    {
        Budgie.PanelMain app;
        Gtk.init(ref args);

        try {
            var opt_context = new OptionContext("- Budgie Panel");
            opt_context.set_help_enabled(true);
            opt_context.add_main_entries(options, null);
            opt_context.parse(ref args);
        } catch (OptionError e) {
            stdout.printf("Error: %s\nRun with --help to see valid options\n", e.message);
            return 0;
        }

        app = new Budgie.PanelMain();

        if (invoke_menu) {
            try {
                app.register(null);
                app.activate_action("menu", null);
                Process.exit(0);
            } catch (Error e) {
                stderr.printf("Error activating menu: %s\n", e.message);
                return 1;
            }
        } else if (invoke_prefs) {
            try {
                app.register(null);
                app.activate_action("prefs", null);
                Process.exit(0);
            } catch (Error e) {
                stderr.printf("Error activating prefs: %s\n", e.message);
                return 1;
            }
        }
        return app.run(args);
    }
} // End BudgiePanelMain

} // End Budgie namespace
