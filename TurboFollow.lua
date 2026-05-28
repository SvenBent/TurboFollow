_addon.name = 'TurboFollow'
_addon.author = 'Daneblood'
_addon.version = '26.05.22g'
_addon.commands = {'turbofollow', 'tfo'}

require('coroutine')
local config = require('config')

-- Settings saved per character:
--   data/<character>.xml
-- min, show_speed, alpha, and strict_mode are persisted.
local defaults = {
    min = 1,
    show_speed = false,
    alpha = 160,
    strict_mode = false,
}

local settings = nil
local settings_file = nil

local function get_character_settings_file()
    local player = windower.ffxi.get_player()

    if not player or not player.name or player.name == '' then
        return nil
    end

    return ('data/%s.xml'):format(player.name:lower())
end

local function copy_defaults()
    local copied = {}

    for key, value in pairs(defaults) do
        copied[key] = value
    end

    return copied
end

local function load_settings()
    local file = get_character_settings_file()

    -- No character name yet: use in-code defaults only.
    if not file then
        if not settings then
            settings = copy_defaults()
        end

        return
    end

    if settings and settings_file == file then
        return
    end

    settings_file = file
    settings = config.load(settings_file, defaults) or copy_defaults()

    settings.min = tonumber(settings.min) or defaults.min

    if settings.show_speed == nil then
        settings.show_speed = defaults.show_speed
    end

    if settings.strict_mode == nil then
        settings.strict_mode = defaults.strict_mode
    end

    settings.alpha = tonumber(settings.alpha) or defaults.alpha
    settings.alpha = math.min(math.max(0, settings.alpha), 255)
end

local function save_settings()
    if not settings then
        return
    end

    settings_file = get_character_settings_file()

    -- If no character is loaded, keep runtime defaults and do not create files.
    if not settings_file then
        return
    end

    local data_path = windower.addon_path .. 'data'

    if not windower.dir_exists(data_path) then
        windower.create_dir(data_path)
    end

    -- Persist character settings. Do not save speed box UI settings.
--    settings.speed_display = nil

    config.save(settings)
end

load_settings()

-- Follow state.
local broadcasting = false
local following = false
local follower_count = 0

local target_x = nil
local target_y = nil
local target_zone = nil

local min_dist_sq = settings.min * settings.min
local max_dist_sq = 50 * 50

local repeated = false
local running = false
local frame_toggle = false

-- Leader IPC send cache.
local last_sent_x = nil
local last_sent_y = nil
local last_sent_zone = nil
local jitter_threshold_sq = 0.0025

-- ShowSpeed state.
local texts = nil
local speed_box = nil
local speed_box_visible = false
local last_speed_text = nil
local speed_x = nil
local last_party_count = nil

local speed_display = {
    bg = {
        alpha = defaults.alpha,
    },
    flags = {
        bottom = true,
        bold = true,
    },
    text = {
        size = 12,
    },
}

local function clear_target()
    target_x = nil
    target_y = nil
    target_zone = nil
end

local function stop_running()
    if running then
        windower.ffxi.run(false)
        running = false
    end
end

local function get_self_name()
    local self = windower.ffxi.get_player()
    return self and self.name and self.name:lower() or nil
end

local function send_stopfollowing()
    if not following then
        return
    end

    local self_name = get_self_name()

    if self_name then
        windower.send_ipc_message('stopfollowing ' .. following .. ' ' .. self_name)
    else
        windower.send_ipc_message('stopfollowing ' .. following)
    end
end

local function start_following(name)
    if not name or name == '' then
        return false
    end

    name = name:lower()

    -- This changes what this character follows.
    -- It does not clear broadcasting, so follow chains can work.
    local self_name = get_self_name()

    if following and following ~= name then
        send_stopfollowing()
    end

    following = name
    clear_target()
    stop_running()

    -- Tell the leader explicitly who is following it.
    -- Format: following <leader> <follower>
    if self_name then
        windower.send_ipc_message('following ' .. following .. ' ' .. self_name)
    else
        windower.send_ipc_message('following ' .. following)
    end

    -- Initial server follow helps establish facing/targeting.
    -- Actual movement is IPC-driven after updates arrive.
--    windower.ffxi.follow()

    return true
end

local function become_leader()
    local self = windower.ffxi.get_player()

    if not self and not repeated then
        repeated = true
        windower.send_command('@wait 1; TurboFollow followme')
        return
    end

    if not self then
        return
    end

    repeated = false

    -- New followme leader overrides previous group leader.
    broadcasting = false
    following = false
    follower_count = 0

    clear_target()
    stop_running()

    windower.send_ipc_message('follow ' .. self.name:lower())
end

local function move_to_target()
    if target_x == nil or target_y == nil or target_zone == nil then
        stop_running()
        return
    end

    local self = windower.ffxi.get_mob_by_target('me')
    local info = windower.ffxi.get_info()

    if not self or not info then
        return
    end

    local dx = target_x - self.x
    local dy = target_y - self.y
    local dist_sq = dx * dx + dy * dy

    if target_zone == info.zone and dist_sq > min_dist_sq and dist_sq < max_dist_sq then
        local len = math.sqrt(dist_sq)

        if len < 1 then
            len = 1
        end

        windower.ffxi.run(dx / len, dy / len)
        running = true
    else
        stop_running()
    end
end

-- Between IPC updates, only enforce stop/safety checks.
local function check_stop_only()
    if not running or target_x == nil or target_y == nil or target_zone == nil then
        return
    end

    local self = windower.ffxi.get_mob_by_target('me')
    local info = windower.ffxi.get_info()

    if not self or not info then
        return
    end

    local dx = target_x - self.x
    local dy = target_y - self.y
    local dist_sq = dx * dx + dy * dy

    if target_zone ~= info.zone
    or dist_sq <= min_dist_sq
    or dist_sq >= max_dist_sq then
        stop_running()
    end
end

local function send_position_if_needed()
    local self = windower.ffxi.get_mob_by_target('me')
    local info = windower.ffxi.get_info()

    if not self or not info then
        return
    end

    if last_sent_x and last_sent_y and last_sent_zone == info.zone then
        local dx = self.x - last_sent_x
        local dy = self.y - last_sent_y

        if (dx * dx + dy * dy) < jitter_threshold_sq then
            return
        end
    end

    last_sent_x = self.x
    last_sent_y = self.y
    last_sent_zone = info.zone

    windower.send_ipc_message(('update %s %s %s %s'):format(self.name:lower(), info.zone, self.x, self.y))
end

local function hide_speed_box()
    if speed_box and speed_box_visible then
        speed_box:hide()
        speed_box_visible = false
    end
end

local function show_speed_box()
    if speed_box and not speed_box_visible then
        speed_box:show()
        speed_box_visible = true
    end
end

local function ensure_speed_box()
    if speed_box then
        return
    end

    if not texts then
        texts = require('texts')
    end

    speed_display.bg.alpha = settings.alpha

    -- Use the same texts.new(text, settings) pattern as DParty.
    speed_box = texts.new('  +0', speed_display)
    speed_box:hide()
    speed_box_visible = false
    last_speed_text = nil
end

local function update_speed_box_position()
    if not speed_box then
        return
    end

    local party = windower.ffxi.get_party()
	local party_count = party and party.party1_count or 1

    if not speed_x then
        speed_x = windower.get_windower_settings().ui_x_res - 166
        speed_box:pos_x(speed_x)
    end

    if party_count ~= last_party_count then
        last_party_count = party_count
        speed_box:pos_y(-20 * party_count - 24)
    end
end

local function get_speed_text(mob)
    local speed_value

    -- Normal movement uses base 5. Mounted movement uses base 4.
    -- TargetInfo uses status 5/85 for mounted speed handling.
    if mob.status == 5 or mob.status == 85 then
        speed_value = mob.movement_speed * 25
    else
        speed_value = mob.movement_speed * 20 - 100
    end

    return '%+4.0f':format(speed_value)
end

local function update_speed_display()
    ensure_speed_box()

    local self = windower.ffxi.get_mob_by_target('me')

    if not self or not self.movement_speed then
        hide_speed_box()
        return
    end

    update_speed_box_position()

    local speed_text = get_speed_text(self)

    if speed_text ~= last_speed_text then
        speed_box:text(speed_text)
        last_speed_text = speed_text
    end

    show_speed_box()
end

windower.register_event('unload', function()
    hide_speed_box()

    windower.send_command('TurboFollow stop')
    coroutine.sleep(0.25)
end)

windower.register_event('login', function()
    load_settings()
    min_dist_sq = settings.min * settings.min
end)

windower.register_event('addon command', function(command, ...)
    command = command and command:lower() or nil

    if not command then
        windower.add_to_chat(207, 'TurboFollow: Provide a name to follow, or "me" to make others follow you.')
        windower.add_to_chat(207, 'TurboFollow: Use //tfo help for command list.')
        return
    end

    if command == 'followme' or command == 'me' then
        become_leader()

    elseif command == 'follow' then
        local name = (...)

        if not name then
            windower.add_to_chat(0, 'TurboFollow: You must provide a player name to follow.')
            return
        end

        start_following(name)

    elseif command == 'stop' then
        send_stopfollowing()

        following = false
        clear_target()
        stop_running()

    elseif command == 'stopall' then
        broadcasting = false
        following = false
        follower_count = 0

        clear_target()
        stop_running()

        windower.send_ipc_message('stop')

    elseif command == 'min' then
        local dist = tonumber((...))

        if not dist then
            return
        end

        dist = math.min(math.max(0.2, dist), 50)

        settings.min = dist
        min_dist_sq = dist * dist
        pcall(save_settings)

        windower.add_to_chat(207, 'TurboFollow: Minimum distance set to ' .. tostring(dist))

    elseif command == 'alpha' then
        local value = tonumber((...))

        if not value then
            windower.add_to_chat(207, 'TurboFollow: Use //tfo alpha <0-255>')
            return
        end

        value = math.floor(math.min(math.max(0, value), 255))

        settings.alpha = value
        speed_display.bg.alpha = value

        if speed_box then
            speed_box:bg_alpha(value)
        end

        pcall(save_settings)

        windower.add_to_chat(207, 'TurboFollow: ShowSpeed background alpha set to ' .. tostring(value))

    elseif command == 'showspeed' then
        local value = (...)

        if value == 'off' then
            settings.show_speed = false
        elseif value == 'on' then
            settings.show_speed = true
        else
            settings.show_speed = not settings.show_speed
        end

        if not settings.show_speed then
            hide_speed_box()
        end

        pcall(save_settings)

        windower.add_to_chat(207, 'TurboFollow: ShowSpeed is ' .. (settings.show_speed and 'ON' or 'OFF'))

    elseif command == 'mode' then
        local value = (...)
        value = value and value:lower() or nil

        if value == 'strict' then
            settings.strict_mode = true
        elseif value == 'soft' then
            settings.strict_mode = false
        else
            settings.strict_mode = not settings.strict_mode
        end

        pcall(save_settings)

        windower.add_to_chat(207,'TurboFollow: Follow mode set to '..(settings.strict_mode and 'strict' or 'soft')
        )

    elseif command == 'help' then
        windower.add_to_chat(207, '-- TurboFollow '.._addon.version..' Commands:')
        windower.add_to_chat(207, '//tfo me - Make others follow this character')
        windower.add_to_chat(207, '//tfo follow <name> or //tfo <name> - Follow a character')
        windower.add_to_chat(207, '//tfo stop - Stop following on this character')
        windower.add_to_chat(207, '//tfo stopall - Stop all TurboFollow clients')
        windower.add_to_chat(207, '-- TurboFollow '.._addon.version..' Settings:')
		windower.add_to_chat(207, '//tfo min <distance> - Set minimum follow distance')
        windower.add_to_chat(207, '//tfo showspeed on|off - Show current movement speed')
        windower.add_to_chat(207, '//tfo alpha <0-255> - Set ShowSpeed background alpha')
        windower.add_to_chat(207, '//tfo mode [strict|soft] - Toggle or set follow steering mode')

    else
        -- Shorthand: //tfo <name>
        start_following(command)
    end
end)

windower.register_event('ipc message', function(msg)
    local command, a, b, c, d =
        msg:match('^(%S+)%s*(%S*)%s*(%S*)%s*(%S*)%s*(%S*)')

    if not command then
        return
    end

    command = command:lower()

    if command == 'stop' then
        broadcasting = false
        following = false
        follower_count = 0

        clear_target()
        stop_running()

    elseif command == 'follow' then
        if not a or a == '' then
            return
        end

        local self_name = get_self_name()
        local new_leader = a:lower()

        -- If this follow command names our own character, we are the newest leader.
        -- Do not follow ourselves.
        if self_name == new_leader then
            broadcasting = false
            following = false
            follower_count = 0

            clear_target()
            stop_running()
            return
        end

        start_following(new_leader)

    elseif command == 'following' then
        local self_name = get_self_name()

        -- a is the intended leader name. If it is us, start/keep broadcasting.
        if not self_name or not a or self_name ~= a:lower() then
            return
        end

        -- Track how many followers are attached to this leader.
        -- This prevents one follower using stop from stopping broadcasts for everyone.
        follower_count = follower_count + 1
        broadcasting = follower_count > 0

        -- Force a fresh position update for the newly attached follower.
        last_sent_x = nil
        last_sent_y = nil
        last_sent_zone = nil
        send_position_if_needed()

    elseif command == 'stopfollowing' then
        local self_name = get_self_name()

        if not self_name or not a or self_name ~= a:lower() then
            return
        end

        follower_count = math.max(0, follower_count - 1)
        broadcasting = follower_count > 0

    elseif command == 'update' then
        if not following or a ~= following then
            return
        end

        target_zone = tonumber(b)
        target_x = tonumber(c)
        target_y = tonumber(d)

        -- Immediate reaction on fresh IPC update.
        move_to_target()
    end
end)

windower.register_event('prerender', function()
    frame_toggle = not frame_toggle

    if frame_toggle then
        if settings.show_speed then
            update_speed_display()
        end

        return
    end

    if broadcasting then
        send_position_if_needed()
    end

    if following then
        if settings.strict_mode then
            move_to_target()
        else
            check_stop_only()
        end
    end
end)
