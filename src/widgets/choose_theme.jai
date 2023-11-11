choose_theme_dialog_handle_event :: (event: Input.Event) -> handled: bool {
    using choose_theme_dialog;
    
    if event.type == .KEYBOARD && event.key_pressed {
        action, mapping := map_event_to_action(event, Action_Open_File_Dialog);
        if action == {
            case .close_dialog;             hide_choose_theme_dialog();     return true;
            case .open_entry_in_place;      apply_selected_theme();         return true;
            case .open_entry_on_the_side;   apply_selected_theme();         return true;

            case .move_up;                  move_cursor(-1, wrap = true);   return true;
            case .move_down;                move_cursor( 1, wrap = true);   return true;
            case .move_up_fast;             move_cursor(-5);                return true;
            case .move_down_fast;           move_cursor( 5);                return true;
            case .move_up_one_page;         move_cursor(-per_page);         return true;
            case .move_down_one_page;       move_cursor( per_page);         return true;
        }
        
        handled := maybe_handle_text_input_event(*input, event);
        return handled;
        
    } else if event.type == .TEXT_INPUT {
        text_input_type_char(*choose_theme_dialog.input, event.utf32);
        refresh_entries();
        return true;
    } 
    
    return false;
}

show_choose_theme_dialog :: () {
    active_global_widget = .choose_theme_dialog;
    temporary_theme = "";
    
    // Save current color scheme
    old_colors = Colors;
     
    text_input_fully_clear(*choose_theme_dialog.input);
    
    refresh_entries();
}

hide_choose_theme_dialog :: () {
    revert_theme_to_previous();    
    activate_editors();
}

apply_theme :: (theme_name: string)  -> success: bool, error_msg: string {
    temporary_theme = theme_name;
    path := tprint("%/%.focus-theme", themes_dir, theme_name);
    
    if !file_exists(path)  {
        apply_old_theme();
        return false, sprint("Couldn't find file '%'", path);
    }
    
    theme_details, success := read_entire_file(path);
    if !success {
        apply_old_theme();
        return false, sprint("Couldn't read file '%'", path);
    }
    
    config := Config.{};
    while true {
        line, found := consume_next_line(*theme_details);
        if !found break;
        
        if line == "" continue;
        
        color_name, value := break_by_spaces(line);
        color_name = trim_right(color_name, ":");
        color_ptr := map_color_name_to_color_struct(*config, color_name);
        if !color_ptr {
            apply_old_theme();
            return false, sprint("Unknown color '%'", color_name);
        }
        value, _ = break_by_spaces(value);
        color, success := hex_to_color(value);
        if !success {
            apply_old_theme();
            return false, sprint("Couldn't parse '%'. Expected a color in the form RRGGBB or RRGGBBAA, got '%'", color_name, value);
        }
        <<color_ptr = color;
    }
    
    Colors = config.colors;
    CODE_COLOR_MAP = refresh_code_color_map();
    platform_set_border_color();
    return true, "";
}

apply_selected_theme :: () -> success: bool, error_msg: string {
    using choose_theme_dialog;
    
    entry := choose_theme_dialog.filtered[selected];
    config.theme = entry.name;
    
    // Get active config file  
    config_path := global_config_path;
    if current_project_name then config_path = sprint("%/%.focus-config", projects_dir, current_project_name);
    
    config_details, success := read_entire_file(config_path);
    if !success then return false, sprint("Couldn't read file '%'", config_path);
    
    // Update file
    parse_config_file(config_details, entry.name);
    temporary_theme = "";
    hide_choose_theme_dialog();
    
    return true, "";
}

revert_theme_to_previous :: () {
    if temporary_theme == "" return;
    temporary_theme = "";
    apply_old_theme();
}

apply_old_theme :: () {
    Colors = old_colors;
    CODE_COLOR_MAP = refresh_code_color_map();
    platform_set_border_color();
}


#scope_file

refresh_entries :: () {
    using choose_theme_dialog;
    
    array_reset_keeping_memory(*filtered);
    
    scroll_to_cursor = .snap;
    scroll_y = 0;
    selected = 0;
    
    filter_chars := decode_utf8_string_to_temp_char_substrings(to_string(input.text));
    
    themes := get_theme_names_from_folder();
    
    for themes {
        score, highlights := fuzzy_match(it, filter_chars);
        if score < 0 continue;
    
        entry := array_add(*filtered);
        entry.name = copy_string(it);  // leak
        entry.highlights = highlights;
        entry.sort_key = cast(u64) score;   
    }
    
    compare_entries :: (e1: Entry, e2: Entry) -> s64 {
        key_diff := cast,no_check(s64) e2.sort_key - cast,no_check(s64) e1.sort_key;
        if key_diff != 0 return key_diff;
        return memcmp(e1.name.data, e2.name.data, min(e1.name.count, e2.name.count));
    }

    quick_sort(filtered, compare_entries);
    for filtered {
        if it.name == config.theme {
            selected = it_index;
            break;
        }
    }
}

move_cursor :: (delta: s64, wrap := false, snap := true) {
    using choose_theme_dialog;

    selected += delta;

    if wrap {
        if selected < 0 then selected = max(0, filtered.count - 1);
        if selected >= filtered.count then selected = 0;
    } else {
        if selected < 0 then selected = 0;
        if selected >= filtered.count then selected = filtered.count - 1;
    }
    scroll_to_cursor = ifx snap then Scroll_Mode.snap else .yes;
    
    entry := filtered[selected];
    success, error_message := apply_theme(entry.name);
    if !success {
        add_user_error(tprint("Couldn't load theme %: %", entry.name, error_message), dismiss_in_seconds = 5);
    }
}

maybe_handle_text_input_event :: (using input: *Text_Input, event: Input.Event) -> handled: bool {
    input_text := copy_temporary_string(to_string(text));
    handled := text_input_handle_event(input, event);
    if handled {
        if input_text != to_string(input.text) then refresh_entries();
        return true;
    }
    return false;
}

get_theme_names_from_folder :: () -> [..] string /* temp */ {
    themes : [..] string;
    themes.allocator = temp;
    
    visitor :: (info: *File_Visit_Info, themes: *[..] string) {
        if !ends_with_nocase(info.full_name, ".focus-theme") return;
        full_path := copy_temporary_string(info.full_name); 
        
        path, basename, extension, name := path_decomp(full_path);   
        file_contents, ok := read_entire_file(full_path );
        if !ok return;
        
        array_add(themes, basename);
    }
    visit_files(themes_dir, recursive = true, *themes, visitor, visit_files = true, visit_directories = false);
    
    return themes;
}


#scope_file

parse_config_file :: (bytes: string, theme: string) {
    tokenizer: Tokenizer = ---;
    tokenizer.buf   = bytes;
    tokenizer.max_t = bytes.data + bytes.count;
    tokenizer.t     = bytes.data;
    
    second_part_start: *u8;
    new_line:          string;
    
    theme_is_set     = false;
    first_part_size := 0;
    second_part_size:= 0;
    buffer_size     := 0;
    
    while true {
        token := get_next_token(*tokenizer);
        if token.type == .eof break;
        
        if style_is_set {
            new_line = tprint("\ntheme: %\n", theme);
            first_part_size = token.start + token.len;
            second_part_start = bytes.data + first_part_size;
            second_part_size = bytes.count - first_part_size;
            buffer_size = bytes.count + new_line.count;
            style_is_set = false;
        } else if theme_is_set {
            new_line = tprint("theme: %", theme);
            first_part_size = token.start;
            second_part_start = bytes.data + first_part_size + token.len;
            second_part_size = bytes.count - (first_part_size + token.len);
            buffer_size = bytes.count + new_line.count - token.len;
            break;
        }
    }
    
    if first_part_size == 0 && second_part_size == 0 {
        new_line = tprint("\n[[style]]\ntheme: %\n", theme);
        first_part_size = bytes.count;
        buffer_size = bytes.count + new_line.count;
    }
       
    update_config_file(buffer_size, bytes.data, first_part_size, second_part_start, second_part_size, new_line);
}

update_config_file :: (buffer_size: s64, first_part: *u8, first_part_size: s64, second_part: *u8, second_part_size: s64, new_line: string) {
    b: String_Builder;
    b.allocator = temp;
    init_string_builder(*b, buffer_size = buffer_size);
    
    append(*b, first_part, first_part_size);
    append(*b, new_line);
    append(*b, second_part, second_part_size);
    s := builder_to_string(*b);
    
    file_path := global_config_path;
    if current_project_name then file_path = sprint("%/%.focus-config", projects_dir, current_project_name);
    success := write_entire_file(file_path, s);
    if !success then print("Write to file is failed");
}

get_next_token :: (using tokenizer: *Tokenizer) -> Token {
    eat_white_space(tokenizer);

    token: Token;
    token.start = cast(s32) (t - buf.data);
    token.type  = .eof;
    if t >= max_t return token;

    start_t = t;

    // Look at the first char as if it's ASCII (if it isn't, this is just a text line)
    char := << t;

    if char == {
        case #char "["; try_parsing_header(tokenizer, *token);
        case #char "#"; parse_comment(tokenizer, *token);
        case;
            if section == {
                case .style; 
                    parse_style_line(tokenizer, *token);
                case;
                    parse_line(tokenizer, *token);
            }
    }

    if t >= max_t then t = max_t;
    token.len = cast(s32) (t - start_t);

    return token;
}

try_parsing_header :: (using tokenizer: *Tokenizer, token: *Token) {
    token.type = .default;
    old_t := t;

    eat_until_newline_or_comment(tokenizer);

    str: string = ---;
    str.data  = old_t;
    str.count = t - old_t;

    str = trim_right(str);

    if str == "[[style]]" {
        section = .style;
        style_is_set = true;
    } else  {
        t = old_t + 1;
    }
}

parse_comment :: (using tokenizer: *Tokenizer, token: *Token) {
    token.type = .comment;

    t += 1;
    eat_until_newline(tokenizer);
}

parse_line :: (using tokenizer: *Tokenizer, token: *Token) {
    token.type = .default;
    
    t += 1;
    eat_until_newline(tokenizer);
}

parse_style_line :: (using tokenizer: *Tokenizer, token: *Token) {
    token.type = .default;
           
    if !is_alnum(<<t) {
        t += 1;
        return;
    }
    
    old_t := t;
    t += 1;
    while t < max_t && is_alnum(<<t) {
        t += 1;
    }
    
    str: string = ---;
    str.data  = old_t;
    str.count = t - old_t;
    if to_lower_copy(str) == "theme" then theme_is_set = true;
    eat_until_newline(tokenizer);
}

eat_until_newline_or_comment :: (using tokenizer: *Tokenizer) {
    while t < max_t && <<t != #char "#" && <<t != #char "\n" {
        t += 1;
    }
}

eat_until_newline :: (using tokenizer: *Tokenizer) {
    while t < max_t && <<t != #char "\n" {
        t += 1;
    }
}

eat_white_space :: (using tokenizer: *Tokenizer) {
    while t < max_t && is_space(<< t) {
        t += 1;
    }
}

#scope_export

choose_theme_dialog: Choose_Theme_Dialog;

Choose_Theme_Dialog :: struct {
    input: Text_Input;
    filtered: [..] Entry;
    selected: s64;
    selected_by_mouse: s64 = -1;  // to remember which entry the left mouse button went down on

    scroll_y: s32;
    scroll_anim := #run Tween_Animation(s32).{ speed = xx 0.1, func = .lerp };
    per_page: s64 = 10;

    scroll_to_cursor: Scroll_Mode = .no;
};

Entry :: struct {
    name: string;
    highlights: [] bool;
    sort_key: u64;
}

temporary_theme := "";

#scope_file

Tokenizer :: struct {
    buf: string;
    max_t:   *u8;
    start_t: *u8;  // cursor when starting parsing new token
    t:       *u8;  // cursor

    section: enum {
        none;
        style; 
    } = .none;
}

Token :: struct {
    start, len: s32;
    type: Type;

    Type :: enum u16 {
        eof;
        comment;
        default;
    }
}

theme_is_set: bool;
style_is_set: bool;

old_colors: Color_Values; 


