local plugin_path, metadata_path = ...
assert(plugin_path and metadata_path, "plugin and metadata paths are required")

local registered_action
local registered_plugin
local scheduled
local executed_commands = {}
local shown = {}
local warnings = {}
local events = {}
local quit_code

package.preload["dispatcher"] = function()
    return {
        registerAction = function(_, name, action)
            registered_action = { name = name, action = action }
        end,
    }
end

package.preload["gettext"] = function()
    return function(text)
        return text
    end
end

package.preload["logger"] = function()
    return {
        info = function() end,
        warn = function(...)
            warnings[#warnings + 1] = { ... }
        end,
    }
end

package.preload["ui/event"] = function()
    return {
        new = function(_, name)
            return { name = name }
        end,
    }
end

package.preload["ui/uimanager"] = function()
    return {
        nextTick = function(_, callback)
            scheduled = callback
        end,
        tickAfterNext = function(_, callback)
            scheduled = callback
        end,
        broadcastEvent = function(_, event)
            events[#events + 1] = event
        end,
        quit = function(_, code)
            quit_code = code
        end,
        show = function(_, message)
            shown[#shown + 1] = message
        end,
    }
end

package.preload["ui/widget/container/widgetcontainer"] = function()
    return {
        extend = function(_, definition)
            return definition
        end,
    }
end

package.preload["ui/widget/infomessage"] = function()
    return {
        new = function(_, options)
            return options
        end,
    }
end

local metadata = dofile(metadata_path)
assert(metadata.fullname == "KUAL Next")
assert(metadata.description:find("Open KUAL Next", 1, true))

local plugin = dofile(plugin_path)
plugin.ui = {
    menu = {
        registerToMainMenu = function(_, value)
            registered_plugin = value
        end,
    },
}
plugin:init()

assert(plugin.name == "kualnext")
assert(plugin.is_doc_only == false)
assert(registered_plugin == plugin)
assert(registered_action.name == "open_kual_next")
assert(registered_action.action.event == "OpenKUALNext")
assert(registered_action.action.title == "Open KUAL Next")
assert(registered_action.action.general == true)

local menu_items = {}
plugin:addToMainMenu(menu_items)
assert(menu_items.kual_next.text == "KUAL Next")
assert(menu_items.kual_next.sorting_hint == "more_tools")

local original_execute = os.execute
os.execute = function(command)
    executed_commands[#executed_commands + 1] = command
    return 0
end

menu_items.kual_next.callback()
assert(type(scheduled) == "function")
assert(#executed_commands == 0, "launch was not deferred")
scheduled()
assert(executed_commands[1] == "test -x /var/local/kmc/bin/sh_integration_launcher")
assert(#shown == 1)
assert(shown[1].icon == nil)
assert(shown[1].text == "KUAL Next is starting.")
assert(#executed_commands == 1, "handoff waits for the notification to repaint")
assert(#events == 0)
assert(quit_code == nil)
scheduled()
assert(executed_commands[2]:find("kual-next-return-to-koreader", 1, true))
assert(executed_commands[2]:find("pidof koreader.sh", 1, true))
assert(executed_commands[2]:find(
    "app://tech.hackerdude.shell_integration.launcher/mnt/us/documents/KUAL%20Next.sh",
    1,
    true
))
assert(not executed_commands[2]:find("launcher.sh", 1, true))
assert(#events == 1 and events[1].name == "Close")
assert(quit_code == 86)

executed_commands = {}
os.execute = function(command)
    executed_commands[#executed_commands + 1] = command
    return 1
end
scheduled = nil
quit_code = nil
plugin:onOpenKUALNext()
assert(type(scheduled) == "function")
scheduled()
assert(#warnings == 1)
assert(#shown == 2)
assert(shown[2].icon == "notice-warning")
assert(shown[2].text:find("requires SH Integration", 1, true))
assert(#executed_commands == 1)
assert(#events == 1)
assert(quit_code == nil)

executed_commands = {}
os.execute = function(command)
    executed_commands[#executed_commands + 1] = command
    return #executed_commands == 1 and 0 or 1
end
scheduled = nil
plugin:onOpenKUALNext()
scheduled()
assert(#shown == 3)
assert(shown[3].text == "KUAL Next is starting.")
assert(#executed_commands == 1)
scheduled()
assert(#warnings == 2)
assert(#shown == 4)
assert(shown[4].text:find("/var/tmp/kual-next.log", 1, true))
assert(#events == 1)
assert(quit_code == nil)

os.execute = original_execute
print("KOReader plugin tests passed")
