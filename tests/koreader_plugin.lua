local plugin_path, metadata_path = ...
assert(plugin_path and metadata_path, "plugin and metadata paths are required")

local registered_action
local registered_plugin
local scheduled
local executed_command
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
    executed_command = command
    return 0
end

menu_items.kual_next.callback()
assert(type(scheduled) == "function")
assert(executed_command == nil, "launch was not deferred")
scheduled()
assert(executed_command == "/bin/sh "
    .. "/mnt/us/koreader/plugins/kualnext.koplugin/launcher.sh "
    .. ">>/var/tmp/kual-next.log 2>&1 &")
assert(#events == 1 and events[1].name == "Close")
assert(quit_code == 86)
assert(#shown == 0)

os.execute = function(command)
    executed_command = command
    return 1
end
scheduled = nil
quit_code = nil
plugin:onOpenKUALNext()
assert(type(scheduled) == "function")
scheduled()
assert(#warnings == 1)
assert(#shown == 1)
assert(shown[1].icon == "notice-warning")
assert(shown[1].text:find("/var/tmp/kual-next.log", 1, true))
assert(#events == 1)
assert(quit_code == nil)

os.execute = original_execute
print("KOReader plugin tests passed")
