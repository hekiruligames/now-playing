obs = obslua

-- Now Playing v2.0
--
-- OBS標準テキストソースへ追加するフィルタとして動作する。
-- 各フィルタインスタンスごとに監視対象のVLCビデオソースと
-- 表示形式を保持し、Lua全体で1本のタイマーから順番に更新する。

local FILTER_ID = "lua_now_playing_filter_v1"
local POLL_INTERVAL_MS = 1000

local instances = {}
local instance_serial = 0

local TAGS = {
    "title",
    "artist",
    "album_artist",
    "album",
    "date",
    "genre",
    "now_playing"
}

local function safe_string(value)
    if value == nil then
        return ""
    end
    return tostring(value)
end

local function trim(value)
    local s = safe_string(value)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_supported_text_source(source)
    if source == nil then
        return false
    end

    local source_id = safe_string(obs.obs_source_get_unversioned_id(source))

    return source_id == "text_ft2_source"
        or source_id == "text_gdiplus"
        or string.find(source_id, "text_ft2_source", 1, true) ~= nil
        or string.find(source_id, "text_gdiplus", 1, true) ~= nil
end

local function release_parent_weak(data)
    if data.parent_weak ~= nil then
        obs.obs_weak_source_release(data.parent_weak)
        data.parent_weak = nil
    end

    data.parent_supported = false
    data.parent_name = ""
end

local function set_parent_source(data, parent)
    release_parent_weak(data)

    if parent == nil then
        return
    end

    data.parent_weak = obs.obs_source_get_weak_source(parent)
    data.parent_supported = is_supported_text_source(parent)
    data.parent_name = safe_string(obs.obs_source_get_name(parent))
    data.last_output = nil

    if not data.parent_supported and not data.unsupported_parent_logged then
        local parent_id = safe_string(obs.obs_source_get_unversioned_id(parent))

        obs.script_log(
            obs.LOG_WARNING,
            "[Now Playing] このフィルタはOBS標準テキストソース向けです。"
                .. " 追加先: " .. data.parent_name
                .. " (" .. parent_id .. ")"
        )

        data.unsupported_parent_logged = true
    end
end

local function get_parent_source(data)
    if data.parent_weak == nil then
        return nil
    end

    local parent = obs.obs_weak_source_get_source(data.parent_weak)

    if parent == nil then
        release_parent_weak(data)
    end

    return parent
end

local function filter_instance_id(filter_source)
    if filter_source == nil then
        return ""
    end

    if safe_string(obs.obs_source_get_unversioned_id(filter_source)) ~= FILTER_ID then
        return ""
    end

    local settings = obs.obs_source_get_settings(filter_source)
    if settings == nil then
        return ""
    end

    local instance_id = safe_string(obs.obs_data_get_string(settings, "_np_instance_id"))
    obs.obs_data_release(settings)
    return instance_id
end

local function discover_parent(data)
    if data.destroyed or data.instance_id == "" then
        return false
    end

    local sources = obs.obs_enum_sources()
    if sources == nil then
        return false
    end

    local found_parent = nil

    for _, parent in ipairs(sources) do
        local filters = obs.obs_source_enum_filters(parent)

        if filters ~= nil then
            for _, filter_source in ipairs(filters) do
                if filter_instance_id(filter_source) == data.instance_id then
                    found_parent = parent
                    break
                end
            end

            obs.source_list_release(filters)
        end

        if found_parent ~= nil then
            break
        end
    end

    if found_parent ~= nil then
        data.unsupported_parent_logged = false
        set_parent_source(data, found_parent)
    end

    obs.source_list_release(sources)
    return found_parent ~= nil
end

local function ensure_parent(data)
    local parent = get_parent_source(data)

    if parent ~= nil then
        obs.obs_source_release(parent)
        return true
    end

    return discover_parent(data)
end

local function get_metadata(source, tag_id)
    local ph = obs.obs_source_get_proc_handler(source)
    if ph == nil then
        return "", false
    end

    local cd = obs.calldata_create()
    if cd == nil then
        return "", false
    end

    obs.calldata_set_string(cd, "tag_id", tag_id)
    local ok = obs.proc_handler_call(ph, "get_metadata", cd)

    local value = ""
    if ok then
        value = trim(obs.calldata_string(cd, "tag_data"))
    end

    obs.calldata_destroy(cd)
    return value, ok
end

local function identity_of(source)
    local title = get_metadata(source, "title")
    local artist = get_metadata(source, "artist")
    local album_artist = get_metadata(source, "album_artist")
    local now_playing = get_metadata(source, "now_playing")

    return table.concat({
        safe_string(title),
        safe_string(artist),
        safe_string(album_artist),
        safe_string(now_playing)
    }, "\n")
end

local function collect_snapshot(source)
    -- 曲切替中に旧曲と新曲のタグが混ざるのを避けるため、
    -- 取得前後の主要情報が同じか確認する。
    local before = identity_of(source)

    local values = {}
    local supported = false

    for _, tag in ipairs(TAGS) do
        local value, ok = get_metadata(source, tag)
        values[tag] = value

        if ok then
            supported = true
        end
    end

    local after = identity_of(source)

    if before ~= after then
        return nil, supported, false
    end

    return values, supported, true
end

local function selected_artist(data, values)
    local artist = trim(values.artist)
    local album_artist = trim(values.album_artist)

    if data.artist_mode == "artist_first" then
        if artist ~= "" then
            return artist
        end
        return album_artist
    elseif data.artist_mode == "artist_only" then
        return artist
    elseif data.artist_mode == "album_artist_only" then
        return album_artist
    else
        if album_artist ~= "" then
            return album_artist
        end
        return artist
    end
end

local function separator_string(data)
    if data.separator_mode == "slash" then
        return " / "
    elseif data.separator_mode == "dash" then
        return " - "
    elseif data.separator_mode == "pipe" then
        return " | "
    else
        return "\n"
    end
end

local function add_item(data, items, seen, label, value)
    value = trim(value)

    if value == "" then
        return
    end

    if seen[value] then
        return
    end
    seen[value] = true

    if data.show_labels then
        table.insert(items, label .. ": " .. value)
    else
        table.insert(items, value)
    end
end

local function build_display(data, values)
    local items = {}
    local seen = {}

    if data.show_title then
        local title = trim(values.title)

        if title == "" then
            title = trim(values.now_playing)
        end

        add_item(data, items, seen, "曲名", title)
    end

    if data.show_artist then
        add_item(data, items, seen, "アーティスト", selected_artist(data, values))
    end

    if data.show_album then
        add_item(data, items, seen, "アルバム", values.album)
    end

    if data.show_date then
        add_item(data, items, seen, "年", values.date)
    end

    if data.show_genre then
        add_item(data, items, seen, "ジャンル", values.genre)
    end

    if #items == 0 then
        return data.empty_fallback
    end

    return data.prefix_text .. table.concat(items, separator_string(data))
end

local function set_parent_text(data, text)
    if data.destroyed or not data.parent_supported then
        return
    end

    text = safe_string(text)

    local parent = get_parent_source(data)
    if parent == nil then
        return
    end

    if not is_supported_text_source(parent) then
        obs.obs_source_release(parent)
        release_parent_weak(data)
        return
    end

    if data.last_output == text then
        obs.obs_source_release(parent)
        return
    end

    local settings = obs.obs_data_create()
    obs.obs_data_set_string(settings, "text", text)
    obs.obs_source_update(parent, settings)
    obs.obs_data_release(settings)
    obs.obs_source_release(parent)

    data.last_output = text
end

local function state_is_inactive(state)
    return state == obs.OBS_MEDIA_STATE_NONE
        or state == obs.OBS_MEDIA_STATE_STOPPED
        or state == obs.OBS_MEDIA_STATE_ENDED
        or state == obs.OBS_MEDIA_STATE_ERROR
end

local function refresh_instance(data)
    if data == nil or data.destroyed then
        return
    end

    if data.filter_source == nil or not obs.obs_source_enabled(data.filter_source) then
        return
    end

    if not ensure_parent(data) or not data.parent_supported then
        return
    end

    if data.vlc_source_name == nil or data.vlc_source_name == "" then
        return
    end

    local source = obs.obs_get_source_by_name(data.vlc_source_name)
    if source == nil then
        return
    end

    local source_id = safe_string(obs.obs_source_get_unversioned_id(source))
    if source_id ~= "vlc_source" then
        obs.obs_source_release(source)
        return
    end

    local state = obs.obs_source_media_get_state(source)

    if state_is_inactive(state) then
        data.inactive_ticks = data.inactive_ticks + 1

        if data.clear_when_stopped and data.inactive_ticks >= 2 then
            set_parent_text(data, "")
        end

        obs.obs_source_release(source)
        return
    end

    data.inactive_ticks = 0

    local values, supported, stable = collect_snapshot(source)
    obs.obs_source_release(source)

    if not supported then
        if not data.metadata_error_logged then
            obs.script_log(
                obs.LOG_ERROR,
                "[Now Playing] 選択されたVLCビデオソースでは get_metadata を利用できません: "
                    .. safe_string(data.vlc_source_name)
            )
            data.metadata_error_logged = true
        end
        return
    end

    data.metadata_error_logged = false

    if not stable or values == nil then
        return
    end

    set_parent_text(data, build_display(data, values))
end

local function monitor_tick()
    -- destroy等でテーブルが変化しても走査中の状態に影響しにくいよう、
    -- その時点のインスタンス一覧を一度配列へコピーする。
    local current = {}

    for data, _ in pairs(instances) do
        table.insert(current, data)
    end

    for _, data in ipairs(current) do
        if instances[data] and not data.destroyed then
            refresh_instance(data)
        end
    end
end

local function apply_settings(data, settings)
    data.vlc_source_name = obs.obs_data_get_string(settings, "vlc_source")

    data.show_title = obs.obs_data_get_bool(settings, "show_title")
    data.show_artist = obs.obs_data_get_bool(settings, "show_artist")
    data.show_album = obs.obs_data_get_bool(settings, "show_album")
    data.show_date = obs.obs_data_get_bool(settings, "show_date")
    data.show_genre = obs.obs_data_get_bool(settings, "show_genre")

    data.artist_mode = obs.obs_data_get_string(settings, "artist_mode")
    data.separator_mode = obs.obs_data_get_string(settings, "separator_mode")
    data.prefix_text = obs.obs_data_get_string(settings, "prefix_text")
    data.show_labels = obs.obs_data_get_bool(settings, "show_labels")
    data.empty_fallback = obs.obs_data_get_string(settings, "empty_fallback")
    data.clear_when_stopped = obs.obs_data_get_bool(settings, "clear_when_stopped")

    data.last_output = nil
    data.inactive_ticks = 0
    data.metadata_error_logged = false
end

local function add_vlc_sources(list)
    obs.obs_property_list_add_string(list, "（選択なし）", "")

    local sources = obs.obs_enum_sources()
    if sources == nil then
        return
    end

    for _, source in ipairs(sources) do
        local source_id = safe_string(obs.obs_source_get_unversioned_id(source))

        if source_id == "vlc_source" then
            local name = safe_string(obs.obs_source_get_name(source))
            obs.obs_property_list_add_string(list, name, name)
        end
    end

    obs.source_list_release(sources)
end

local function filter_defaults(settings)
    obs.obs_data_set_default_string(settings, "vlc_source", "")

    obs.obs_data_set_default_bool(settings, "show_title", true)
    obs.obs_data_set_default_bool(settings, "show_artist", true)
    obs.obs_data_set_default_bool(settings, "show_album", false)
    obs.obs_data_set_default_bool(settings, "show_date", false)
    obs.obs_data_set_default_bool(settings, "show_genre", false)

    obs.obs_data_set_default_string(settings, "artist_mode", "album_artist_first")
    obs.obs_data_set_default_string(settings, "separator_mode", "newline")
    obs.obs_data_set_default_string(settings, "prefix_text", "♪ ")
    obs.obs_data_set_default_bool(settings, "show_labels", false)
    obs.obs_data_set_default_string(settings, "empty_fallback", "")
    obs.obs_data_set_default_bool(settings, "clear_when_stopped", true)
end

local function filter_properties(data)
    local props = obs.obs_properties_create()

    local vlc_list = obs.obs_properties_add_list(
        props,
        "vlc_source",
        "監視するVLCビデオソース",
        obs.OBS_COMBO_TYPE_LIST,
        obs.OBS_COMBO_FORMAT_STRING
    )
    add_vlc_sources(vlc_list)

    obs.obs_properties_add_bool(props, "show_title", "曲名を表示")
    obs.obs_properties_add_bool(props, "show_artist", "アーティストを表示")
    obs.obs_properties_add_bool(props, "show_album", "アルバムを表示")
    obs.obs_properties_add_bool(props, "show_date", "年を表示")
    obs.obs_properties_add_bool(props, "show_genre", "ジャンルを表示")

    local artist_list = obs.obs_properties_add_list(
        props,
        "artist_mode",
        "アーティストの取得元",
        obs.OBS_COMBO_TYPE_LIST,
        obs.OBS_COMBO_FORMAT_STRING
    )
    obs.obs_property_list_add_string(
        artist_list,
        "Album Artist → Artist の順で補完",
        "album_artist_first"
    )
    obs.obs_property_list_add_string(
        artist_list,
        "Artist → Album Artist の順で補完",
        "artist_first"
    )
    obs.obs_property_list_add_string(
        artist_list,
        "Artist のみ",
        "artist_only"
    )
    obs.obs_property_list_add_string(
        artist_list,
        "Album Artist のみ",
        "album_artist_only"
    )

    local separator_list = obs.obs_properties_add_list(
        props,
        "separator_mode",
        "項目の区切り",
        obs.OBS_COMBO_TYPE_LIST,
        obs.OBS_COMBO_FORMAT_STRING
    )
    obs.obs_property_list_add_string(separator_list, "改行", "newline")
    obs.obs_property_list_add_string(separator_list, " / ", "slash")
    obs.obs_property_list_add_string(separator_list, " - ", "dash")
    obs.obs_property_list_add_string(separator_list, " | ", "pipe")

    obs.obs_properties_add_text(
        props,
        "prefix_text",
        "先頭に付ける文字",
        obs.OBS_TEXT_DEFAULT
    )

    obs.obs_properties_add_bool(
        props,
        "show_labels",
        "「曲名:」「アーティスト:」などの項目名を付ける"
    )

    obs.obs_properties_add_text(
        props,
        "empty_fallback",
        "タグがすべて空の場合\n（空欄可）",
        obs.OBS_TEXT_DEFAULT
    )

    obs.obs_properties_add_bool(
        props,
        "clear_when_stopped",
        "停止・終了時に表示を消す"
    )

    return props
end

local function generate_instance_id()
    instance_serial = instance_serial + 1

    return string.format(
        "np-%d-%d-%d",
        os.time(),
        instance_serial,
        math.floor(os.clock() * 1000000)
    )
end

local function instance_id_is_active(instance_id)
    if instance_id == "" then
        return false
    end

    for existing, _ in pairs(instances) do
        if not existing.destroyed and existing.instance_id == instance_id then
            return true
        end
    end

    return false
end

local function filter_create(settings, source)
    local instance_id = safe_string(obs.obs_data_get_string(settings, "_np_instance_id"))

    -- フィルタ複製などで内部IDが重複した場合は、新しいIDへ差し替える。
    if instance_id == "" or instance_id_is_active(instance_id) then
        instance_id = generate_instance_id()
        obs.obs_data_set_string(settings, "_np_instance_id", instance_id)
    end

    local data = {
        filter_source = source,
        instance_id = instance_id,
        parent_weak = nil,
        parent_supported = false,
        parent_name = "",
        destroyed = false,
        unsupported_parent_logged = false,
        last_output = nil,
        inactive_ticks = 0,
        metadata_error_logged = false
    }

    apply_settings(data, settings)
    instances[data] = true

    return data
end

local function filter_destroy(data)
    if data == nil or data.destroyed then
        return
    end

    instances[data] = nil
    data.destroyed = true
    release_parent_weak(data)
    data.filter_source = nil
end

local function filter_update(data, settings)
    if data == nil or data.destroyed then
        return
    end

    apply_settings(data, settings)
end

local function filter_save(data, settings)
    if data == nil or data.destroyed then
        return
    end

    obs.obs_data_set_string(settings, "_np_instance_id", data.instance_id)
end

local function filter_video_render(data, effect)
    if data == nil or data.destroyed or data.filter_source == nil then
        return
    end

    -- このフィルタは映像そのものを加工しない。
    -- 親テキストソースの描画はそのまま次へ渡す。
    obs.obs_source_skip_video_filter(data.filter_source)
end

local filter_info = {}
filter_info.id = FILTER_ID
filter_info.type = obs.OBS_SOURCE_TYPE_FILTER
filter_info.output_flags = obs.OBS_SOURCE_VIDEO
filter_info.get_name = function()
    return "Now Playing"
end
filter_info.create = filter_create
filter_info.destroy = filter_destroy
filter_info.update = filter_update
filter_info.save = filter_save
filter_info.get_defaults = filter_defaults
filter_info.get_properties = filter_properties
filter_info.video_render = filter_video_render

obs.obs_register_source(filter_info)

function script_description()
    return [[
Now Playing v2.0

OBS標準テキストソースの「フィルタ」から「Now Playing」を追加して使用します。
各フィルタごとに、監視するVLCビデオソースと表示形式を個別設定できます。

・複数のテキストソース / 複数シーンで個別設定可能
・同じVLCビデオソースを複数のNow Playingフィルタから参照可能
・表示先テキストソースを選ぶ設定は不要
・Lua全体で1本のタイマーを使用し、1秒ごとに登録済みフィルタを順番に更新
・曲名 / アーティスト / アルバム / 年 / ジャンルに対応
・Artist / Album Artist の補完順を選択可能
・停止 / 終了時の表示クリアに対応

このスクリプトはOBS ProjectおよびVideoLANによる公式ツールではありません。
]]
end

function script_load(settings)
    obs.timer_remove(monitor_tick)
    obs.timer_add(monitor_tick, POLL_INTERVAL_MS)
end

function script_unload()
    obs.timer_remove(monitor_tick)

    for data, _ in pairs(instances) do
        release_parent_weak(data)
    end
end
