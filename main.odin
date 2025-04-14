package main

import "core:fmt"
import "core:mem"
import "core:math"
import "core:os"
import "core:time"
import "core:strings"
import "core:math/rand"
import "core:encoding/json"
import fp "core:path/filepath"
import rl "vendor:raylib"

Vec2 :: [2]f32

Error :: union #shared_nil {
    MainError,
    json.Error,
    json.Unmarshal_Error,
    os.Error,
}

MainError :: enum {
    BadFile
}

BulletType :: enum {
    Bouncer,
    Constructor,
    Bulldozer,
}

Bullet :: struct {
    position: Vec2,
    direction: Vec2,
    speed: f32,
    type: BulletType,
}

BulletSpawner :: struct {
    x: f32,
    y: f32,
    spawn_frequency: f32,
    velocity: f32,
    timer: f32,
    bullet_type: string,
    bullet_type_enum: BulletType,
}

Wall :: struct {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    invulnerable: bool,
}

State :: struct {
    map_width: i32,
    map_height: i32,

    player_position: Vec2, 
    player_speed: f32,
    walls: [dynamic]Wall,
    bullet_spawners: [dynamic]BulletSpawner,

    bullets: [dynamic]Bullet,

    wall_thickness: u32,
    game_over: bool,
    time_alive: f32,
}

NORTH :: Vec2 {  0, -1 }
EAST  :: Vec2 {  1,  0 }
SOUTH :: Vec2 {  0,  1 }
WEST  :: Vec2 { -1,  0 }

PLAYER_RADIUS :: 20
BULLET_RADIUS :: 8

CONTRUCTED_WALL_LENGHT :: 300

ARENA :: #config(ARENA, false)
when ARENA {
    AllocatorDataType :: mem.Arena
} else {
    AllocatorDataType :: AllocatorData
}

alloc_data: AllocatorDataType

init_allocator :: proc(alloc_data: ^AllocatorDataType) {
    total_bytes :: 8196
    when ARENA {
        data, err := mem.alloc_bytes(total_bytes)
        assert(err == .None)
        mem.arena_init(alloc_data, data)
    } else {
        init_allocator_data(alloc_data, total_bytes)
    }
}

free_allocator :: proc(alloc_data: ^AllocatorDataType) {
    when ARENA {
        mem.free_bytes(alloc_data.data)
    } else {
        free_allocator_data(alloc_data)
    }
}

get_allocator :: proc(alloc_data: ^AllocatorDataType) -> mem.Allocator {
    when ARENA {
        return mem.arena_allocator(alloc_data)
    } else {
        return my_allocator(alloc_data)
    }
}

vec_perpendicular :: proc(vec: Vec2) -> Vec2 {
    return Vec2 {vec.y, -vec.x}
}

vec_perpendicular_to_wall :: proc(wall: Wall) -> Vec2 {
    wall_vec := Vec2{wall.x2, wall.y2} - Vec2{wall.x1, wall.y1}
    return rl.Vector2Normalize(vec_perpendicular(wall_vec))
}

check_wall_collision :: proc(wall: Wall, center: Vec2, radius: f32, state: State) -> bool {
    perpend := vec_perpendicular_to_wall(wall)
    wall_start := Vec2{wall.x1, wall.y1}
    wall_end := Vec2{wall.x2, wall.y2}

    half_thick := cast(f32) state.wall_thickness / 2

    left_start  := wall_start + perpend * half_thick
    left_end := wall_end + perpend * half_thick
                                        
    right_start := wall_start - perpend * half_thick
    right_end := wall_end - perpend * half_thick

    return (rl.CheckCollisionCircleLine(center, radius, left_start, left_end)
        || rl.CheckCollisionCircleLine(center, radius, right_start, right_end)
        || rl.CheckCollisionCircleLine(center, radius, right_start, left_start)
        || rl.CheckCollisionCircleLine(center, radius, right_end, left_end))
}

random_direction :: proc() -> Vec2 {
    return rl.Vector2Normalize(
        Vec2 { rand.float32_range(-1, 1), rand.float32_range(-1, 1) }
    )
}

update_state :: proc(state: ^State, dt: f32) {
    player_movement_direction: Vec2

    if (rl.IsKeyDown(.W)) do player_movement_direction += NORTH
    if (rl.IsKeyDown(.D)) do player_movement_direction += EAST
    if (rl.IsKeyDown(.S)) do player_movement_direction += SOUTH
    if (rl.IsKeyDown(.A)) do player_movement_direction += WEST
    
    player_new_position := (state.player_position
        + rl.Vector2Normalize(player_movement_direction) * state.player_speed * dt)

    all_good := true
    for &wall in state.walls {
        if (check_wall_collision(wall, player_new_position, PLAYER_RADIUS, state^)) {
            all_good = false
            break
        }
    }

    if (all_good) {
        state.player_position += rl.Vector2Normalize(player_movement_direction) * state.player_speed * dt
    }

    // Update spawners' timers
    for &spawner in state.bullet_spawners {
        spawner.timer += dt

        if spawner.timer > spawner.spawn_frequency {
            spawner.timer = 0

            // Spawn bullet
            new_bullet := Bullet {
                position = {spawner.x,  spawner.y},
                type = spawner.bullet_type_enum,
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
            if (check_wall_collision(wall, bullet_new_position, BULLET_RADIUS, state^)) {
                bullet_will_collide_with_wall = true

                switch bullet.type {
                case .Bulldozer:
                    unordered_remove(&state.walls, wall_index)
                    unordered_remove(&state.bullets, bullet_index)
                case .Constructor:

                    new_wall_dir := Vec2(vec_perpendicular(bullet.direction))
                    new_wall_center := (bullet_new_position 
                        + BULLET_RADIUS * rl.Vector2Normalize(bullet.direction))

                    new_wall_start := new_wall_center + new_wall_dir * CONTRUCTED_WALL_LENGHT / 2
                    new_wall_end := new_wall_center - new_wall_dir * CONTRUCTED_WALL_LENGHT / 2

                    new_wall := Wall {
                        x1 = new_wall_start.x,
                        y1 = new_wall_start.y,
                        x2 = new_wall_end.x,
                        y2 = new_wall_end.y,
                    }

                    append(&state.walls, new_wall)
                    unordered_remove(&state.bullets, bullet_index)

                case .Bouncer:
                    bullet_dir := -bullet.direction
                    // TODO: This function only returns the perpendicular vec, but a wall actually has 4 sides.
                    wall_perpend_vec := rl.Vector2Normalize(vec_perpendicular_to_wall(wall))

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
        if !bullet_will_collide_with_wall do bullet.position = bullet_new_position

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

    if !state.game_over do state.time_alive += dt
}

draw_wall :: proc(wall: Wall, state: State) {
    angle := rl.Vector2LineAngle({wall.x1, wall.y1}, {wall.x2, wall.y2})
    dist := rl.Vector2Distance({wall.x1, wall.y1}, {wall.x2, wall.y2})
    rect := rl.Rectangle {
        wall.x1,
        wall.y1,
        dist,
        cast(f32)state.wall_thickness,
    }

    origin := Vec2 {0, (cast(f32)state.wall_thickness / 2)}
    rl.DrawRectanglePro(rect, origin , math.to_degrees(-angle), rl.BLUE)
}

draw :: proc(state: State) {

    rl.DrawCircle(cast(i32) state.player_position.x, cast(i32) state.player_position.y, PLAYER_RADIUS, rl.GREEN)

    for bullet in state.bullets {
        rl.DrawCircle(cast(i32) bullet.position.x, cast(i32) bullet.position.y, BULLET_RADIUS, rl.RED)
    }

    for spawner in state.bullet_spawners {
        rl.DrawRing({spawner.x, spawner.y}, 8, 13, 0, 360, 20, rl.PINK)
    }

    for &wall in state.walls do draw_wall(wall, state)
}

read_json_as_struct :: proc(state: ^State, filename: string) -> (err: Error) {
    data := os.read_entire_file_from_filename_or_err(filename, context.temp_allocator) or_return
    json.unmarshal(data, state, allocator = get_allocator(&alloc_data)) or_return

    bullet_type := make(map[string]BulletType, context.temp_allocator)
    bullet_type["bouncer"] = .Bouncer
    bullet_type["bulldozer"] = .Bulldozer
    bullet_type["constructor"] = .Constructor

    for &spawner in state.bullet_spawners {
        if !(spawner.bullet_type in bullet_type) do panic("Invalid bullet type")
        spawner.bullet_type_enum = bullet_type[spawner.bullet_type]
    }

    state.player_position = {300, 300}
    return
}

main :: proc() {
    c := context

    rand.reset(time.read_cycle_counter())

    init_allocator(&alloc_data)
    defer free_allocator(&alloc_data)

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
        defer free_all(context.temp_allocator)

        if state != nil {
            if !state.game_over do update_state(state, rl.GetFrameTime())

            if state.map_width != window_width || state.map_height != window_height {
                rl.SetWindowSize(state.map_width, state.map_height)
                window_width = state.map_width
                window_height = state.map_height

                fmt.println("Reszied window", window_width, window_height)
            }
        }

        rl.BeginDrawing()
        {
            rl.ClearBackground(rl.RAYWHITE)
            if state != nil {
                draw(state^)

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

                scroll_index: i32
                active: i32 = -1

                curr_maps := fp.glob("maps/*.json", context.temp_allocator) or_else []string{}

                curr_maps_names := make([dynamic]string, context.temp_allocator)

                for map_filepath in curr_maps {
                    _, filename := fp.split(map_filepath)
                    append(&curr_maps_names,  filename)
                }

                list_view_str, err := strings.join(curr_maps_names[:], ";", allocator = context.temp_allocator)
                assert(err == nil)
                maps_list_view_cstr := strings.clone_to_cstring(list_view_str, allocator = context.temp_allocator)

                dropdown_rect := rl.Rectangle {20, 210, 120, f32(len(curr_maps_names)) * 35}
                rl.GuiListView(dropdown_rect, maps_list_view_cstr, &scroll_index, &active)

                if active >= 0 {
                    list_view_visibility = false

                    if state != nil {
                        free_all(get_allocator(&alloc_data))
                    }

                    state = new(State, get_allocator(&alloc_data))
                    err := read_json_as_struct(state, curr_maps[active])

                    if err != nil do fmt.eprintln("got error: %v", err)
                }
            }

            if state != nil && state.game_over {
                rl.DrawText("you died!", 200, 300, 40, rl.GRAY)
            }
        }
        rl.EndDrawing()
    }
}
