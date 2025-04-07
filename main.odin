package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:time"
import "core:strings"
import "core:math/rand"
import "core:encoding/json"
import fp "core:path/filepath"
import rl "vendor:raylib"

NORTH :: rl.Vector2 { 0, -1 }
EAST  :: rl.Vector2 { 1, 0 }
SOUTH :: rl.Vector2 { 0, 1 }
WEST  :: rl.Vector2 { -1, 0 }

PLAYER_RADIUS :: 20
BULLET_RADIUS :: 8

CONTRUCTED_WALL_LENGHT :: 300

alloc_data: AllocatorData

BulletType :: enum {
    Bouncer,
    Constructor,
    Bulldozer,
}

Bullet :: struct {
    position: rl.Vector2,
    direction: rl.Vector2,
    speed: f32,
    type: BulletType,
}

BulletSpawner :: struct {
    position: rl.Vector2,
    spawn_frequency: f32,
    timer: f32,
    velocity: f32,
    bullet_type: BulletType,
}

Wall :: struct {
    start: rl.Vector2,
    end: rl.Vector2,
    invulnerable: bool,
}

State :: struct {
    map_width: i32,
    map_height: i32,

    player_position: rl.Vector2, 
    player_speed: f32,
    walls: [dynamic]Wall,
    bullets: [dynamic]Bullet,
    spawners: [dynamic]BulletSpawner,

    wall_thickness: u32,
    game_over: bool,
    time_alive: f32,
}

vec_perpendicular :: proc(vec: rl.Vector2) -> rl.Vector2 {
    return rl.Vector2 {vec.y, -vec.x}
}
vec_perpendicular_to_wall :: proc(wall: ^Wall) -> rl.Vector2 {
    wall_vec := wall.end - wall.start
    return rl.Vector2Normalize(vec_perpendicular(wall_vec))
}

check_wall_collision :: proc(wall: ^Wall, center: rl.Vector2, radius: f32, state: ^State) -> bool {
    perpend := vec_perpendicular_to_wall(wall)

    half_thick := cast(f32) state.wall_thickness / 2

    left_start  := wall.start + perpend * half_thick
    left_end := wall.end + perpend * half_thick
                                        
    right_start := wall.start - perpend * half_thick
    right_end := wall.end - perpend * half_thick

    return (rl.CheckCollisionCircleLine(center, radius, left_start, left_end)
        || rl.CheckCollisionCircleLine(center, radius, right_start, right_end)
        || rl.CheckCollisionCircleLine(center, radius, right_start, left_start)
        || rl.CheckCollisionCircleLine(center, radius, right_end, left_end))
}

random_direction :: proc() -> rl.Vector2 {
    return rl.Vector2Normalize(
        rl.Vector2 { rand.float32_range(-1, 1), rand.float32_range(-1, 1) }
    )
}

update_state :: proc(state: ^State, dt: f32) {
    context.allocator = my_allocator(&alloc_data)

    player_movement_direction: rl.Vector2

    if (rl.IsKeyDown(.W)) { player_movement_direction += NORTH }
    if (rl.IsKeyDown(.D)) { player_movement_direction += EAST }
    if (rl.IsKeyDown(.S)) { player_movement_direction += SOUTH }
    if (rl.IsKeyDown(.A)) { player_movement_direction += WEST }
    
    player_new_position := (state.player_position
        + rl.Vector2Normalize(player_movement_direction) * state.player_speed * dt)

    all_good := true
    for &wall in state.walls {
        if (check_wall_collision(&wall, player_new_position, PLAYER_RADIUS, state)) {
            all_good = false
            break
        }
    }

    if (all_good) {
        state.player_position += rl.Vector2Normalize(player_movement_direction) * state.player_speed * dt
    }

    // Update spawners' timers
    for &spawner in state.spawners {
        spawner.timer += dt

        if spawner.timer > spawner.spawn_frequency {
            spawner.timer = 0

            // Spawn bullet
            new_bullet := Bullet {
                position = spawner.position,
                type = spawner.bullet_type,
                direction = random_direction(),
                speed = spawner.velocity,
            }

            append(&state.bullets, new_bullet)
        }
    }


    // Update bullets' positions
    #reverse for &bullet, bullet_index in state.bullets {
        bullet_new_position := bullet.position + bullet.direction * bullet.speed * dt;

        bullet_will_collide_with_wall := false
        #reverse for &wall, wall_index in state.walls {
            if (check_wall_collision(&wall, bullet_new_position, BULLET_RADIUS, state)) {
                bullet_will_collide_with_wall = true

                switch bullet.type {
                case .Bulldozer:
                    unordered_remove(&state.walls, wall_index)
                    unordered_remove(&state.bullets, bullet_index)
                case .Constructor:

                    new_wall_dir := rl.Vector2(vec_perpendicular(bullet.direction))
                    new_wall_center := (bullet_new_position 
                        + BULLET_RADIUS * rl.Vector2Normalize(bullet.direction))

                    new_wall_start := new_wall_center + new_wall_dir * CONTRUCTED_WALL_LENGHT / 2
                    new_wall_end := new_wall_center - new_wall_dir * CONTRUCTED_WALL_LENGHT / 2

                    new_wall := Wall {
                        start = new_wall_start,
                        end = new_wall_end,
                    }

                    append(&state.walls, new_wall)
                    unordered_remove(&state.bullets, bullet_index)

                case .Bouncer:
                    bullet_dir := -bullet.direction
                    // TODO: This function only returns the perpendicular vec, but a wall actually has 4 sides.
                    wall_perpend_vec := rl.Vector2Normalize(vec_perpendicular_to_wall(&wall))

                    if rl.Vector2DotProduct(wall_perpend_vec, bullet_dir) < 0 {
                        wall_perpend_vec = -wall_perpend_vec
                    }

                    bullet_dir_wall_perpend_component := (wall_perpend_vec
                         * rl.Vector2DotProduct(wall_perpend_vec, bullet_dir))
                    bullet_dir_wall_parallel_component := bullet_dir - bullet_dir_wall_perpend_component

                    bullet.direction = bullet_dir_wall_perpend_component - bullet_dir_wall_parallel_component
                }

                break
            }
        }

        // Update bullet's position
        if !bullet_will_collide_with_wall {
            bullet.position = bullet_new_position
        }

        // Check colision with player
        if rl.CheckCollisionCircles(bullet.position, BULLET_RADIUS, state.player_position, PLAYER_RADIUS) {
            state.game_over = true
            unordered_remove(&state.bullets, bullet_index)
            continue
        }

        // Remove bullets that are out size the map
        if !rl.CheckCollisionCircleRec(bullet.position, BULLET_RADIUS, {0, 0, cast(f32)state.map_width, cast(f32)state.map_height}) {
            unordered_remove(&state.bullets, bullet_index)
        }
    }

    if !state.game_over {
        state.time_alive += dt
    }
}

draw_wall :: proc(wall: ^Wall, state: ^State) {
    angle := rl.Vector2LineAngle(wall.start, wall.end)
    dist := rl.Vector2Distance(wall.start, wall.end)
    rect := rl.Rectangle {
        wall.start.x,
        wall.start.y,
        dist,
        cast(f32)state.wall_thickness,
    }

    origin := rl.Vector2 {0, (cast(f32)state.wall_thickness / 2)}
    rl.DrawRectanglePro(rect, origin , math.to_degrees(-angle), rl.BLUE)
}

draw :: proc(state: ^State) {
    context.allocator = context.temp_allocator
    defer free_all()

    rl.DrawCircle(cast(i32) state.player_position.x, cast(i32) state.player_position.y, PLAYER_RADIUS, rl.GREEN)

    for bullet in state.bullets {
        rl.DrawCircle(cast(i32) bullet.position.x, cast(i32) bullet.position.y, BULLET_RADIUS, rl.RED)
    }

    for spawner in state.spawners {
        rl.DrawRing(spawner.position, 8, 13, 0, 360, 20, rl.PINK)
    }

    for &wall in state.walls {
        draw_wall(&wall, state)
    }
}

alloc_and_init_state :: proc(json_obj: ^json.Object) -> ^State {
    context.allocator = my_allocator(&alloc_data)

    state := new(State)
    state^ = State {
        player_position = {300, 300},
        walls = make([dynamic]Wall, 0, len(json_obj["walls"].(json.Array)))
    }

    state.map_width = i32(json_obj["map_width"].(json.Float))
    state.map_height = i32(json_obj["map_width"].(json.Float))
    state.wall_thickness = u32(json_obj["wall_thickness"].(json.Float))
    state.player_speed = f32(json_obj["player_speed"].(json.Float))

    for wall_json in json_obj["walls"].(json.Array) {
        new_wall := Wall {
            start = {
                f32(wall_json.(json.Object)["x1"].(json.Float)),
                f32(wall_json.(json.Object)["y1"].(json.Float))
            },
            end = {
                f32(wall_json.(json.Object)["x2"].(json.Float)),
                f32(wall_json.(json.Object)["y2"].(json.Float))
            },
           invulnerable = false,
        }


        if wall_json.(json.Object)["invulnerable"] != nil {
            new_wall.invulnerable = wall_json.(json.Object)["invulnerable"].(json.Boolean)
        }

        append(&state.walls, new_wall)

    }

    for bullet_spawner_json in json_obj["bullet_spawners"].(json.Array) {
        new_spawner := BulletSpawner {
            spawn_frequency = f32(bullet_spawner_json.(json.Object)["spawn_frequency"].(json.Float)),
            velocity = f32(bullet_spawner_json.(json.Object)["velocity"].(json.Float)),
            position =  {
                f32(bullet_spawner_json.(json.Object)["x"].(json.Float)),
                f32(bullet_spawner_json.(json.Object)["y"].(json.Float))
            }
        }

        bullet_type_str := bullet_spawner_json.(json.Object)["bullet_type"].(json.String)
        if bullet_type_str == "bouncer" {
            new_spawner.bullet_type = .Bouncer
        } else if bullet_type_str == "bulldozer" {
            new_spawner.bullet_type = .Bulldozer
        } else if bullet_type_str == "constructor" {
            new_spawner.bullet_type = .Constructor
        } else {
            panic("Invalid bullet type")
        }

        append(&state.spawners, new_spawner)
    }

    return state
}

get_current_maps_filenames :: proc() -> []os.File_Info {
    maps_dir_fd, open_err := os.open("maps/")
    defer os.close(maps_dir_fd)
    dir_items, read_err := os.read_dir(maps_dir_fd, -1, allocator = context.temp_allocator)

    maps_files := make([dynamic]os.File_Info, allocator = context.temp_allocator)
    for item in dir_items {
        if os.is_file(item.fullpath) && fp.ext(item.name) == ".json" {
            append(&maps_files, item)
        }
    }

    return maps_files[:]
}

read_json_config :: proc(filename: string) -> json.Value {
    data, ok := os.read_entire_file_from_filename(filename, allocator = context.temp_allocator)

    if !ok {
        panic("Data read incorrectly.")
    }

    json_data, err := json.parse(data, allocator = context.temp_allocator)
    if err != .None {
        panic("Json couldn't be parsed")
    }

    return json_data
}

main :: proc() {
    c := context

    rand.reset(time.read_cycle_counter())


    init_allocator_data(&alloc_data, 8196)
    defer free_allocator_data(&alloc_data)

    state: ^State

    window_height: i32 = 600
    window_width: i32 = 600

    rl.InitWindow(window_height, window_width, "bullet dodge");
    rl.SetTargetFPS(60)

    gui_dropdown_mode := false
    gui_map_selected: i32
    label_rect := rl.Rectangle {20, 170, 120, 40}
    list_view_visibility := false

    for !rl.WindowShouldClose() {

        if state != nil {
            if !state.game_over {
                update_state(state, rl.GetFrameTime())
            }

            if state.map_width != window_width || state.map_height != window_height {
                rl.SetWindowSize(state.map_width, state.map_height)
                window_width = state.map_width
                window_height = state.map_height
            }
        }

        rl.BeginDrawing()
        {
            rl.ClearBackground(rl.RAYWHITE)
            if state != nil {
                draw(state)

                // OnScreenInfo
                rl.DrawText(fmt.ctprintf("Num bullets: %d", len(state.bullets)), 20, 20, 20, rl.GRAY)
                rl.DrawText(fmt.ctprintf("Num walls: %d", len(state.walls)),  20, 50, 20, rl.GRAY)
                rl.DrawText(fmt.ctprintf("Frame time: %.2f", rl.GetFrameTime()), 20, 80, 20, rl.GRAY)
                rl.DrawText(fmt.ctprintf("FPS: %.0f", 1 / rl.GetFrameTime()), 20, 110, 20, rl.GRAY)
                rl.DrawText(fmt.ctprintf("time survived: %.0fs", state.time_alive), 20, 140, 20, rl.GRAY)
            }
            

            if rl.GuiButton(label_rect, "Select map") {
                list_view_visibility = !list_view_visibility
            }

            if list_view_visibility {
                defer free_all(context.temp_allocator)

                scroll_index: i32
                active: i32 = -1

                curr_maps := get_current_maps_filenames()

                curr_maps_names := make([dynamic]string, allocator = context.temp_allocator)

                for map_fileinfo in curr_maps {
                    append(&curr_maps_names, map_fileinfo.name)
                }

                list_view_str, err := strings.join_safe(curr_maps_names[:], ";", allocator = context.temp_allocator)
                assert(err == nil)
                maps_list_view_cstr := strings.clone_to_cstring(list_view_str, allocator = context.temp_allocator)

                dropdown_rect := rl.Rectangle {20, 210, 120, f32(len(curr_maps_names)) * 35}
                rl.GuiListView(dropdown_rect, maps_list_view_cstr, &scroll_index, &active)

                if active >= 0 {
                    list_view_visibility = false

                    if state != nil {
                        free_all(my_allocator(&alloc_data))
                    }

                    json_config := read_json_config(curr_maps[active].fullpath)
                    state = alloc_and_init_state(&json_config.(json.Object))
                }
            }

            if state != nil && state.game_over {
                rl.DrawText("you died!", 200, 300, 40, rl.GRAY)
            }
        }
        rl.EndDrawing()
    }
}
