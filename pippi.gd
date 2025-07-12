extends CharacterBody3D

# === COORDINATE SYSTEM NOTES ===
# Godot uses Y-Up, -Z Forward convention:
# - X: Right/Left (Red axis)
# - Y: Up/Down (Green axis) 
# - Z: Forward/Back (Blue axis, -Z is forward)
# Camera3D nodes face -Z by default

# === MOVEMENT STATES ===
enum MovementState {
	FLOATING,    # Swimming in open water
	GROUNDED     # Crawling on seabed
}

var current_state = MovementState.FLOATING
var state_transition_cooldown = 0.0
const STATE_TRANSITION_DELAY = 0.5  # Prevent rapid state switching

# === MOVEMENT PROPERTIES ===
@export_group("Swimming")
@export var swim_power = 8.0          # Forward swimming strength
@export var water_resistance = 0.88   # Underwater drag (lower = more resistance)
@export var buoyancy = 1.5            # Gentle upward float when idle
@export var max_speed = 12.0          # Terminal swimming speed

@export_group("Seabed Movement")
@export var crawl_power = 4.0         # Crawling strength on seabed
@export var ground_resistance = 0.75  # Ground drag (more resistance than water)
@export var ground_max_speed = 6.0    # Slower max speed on ground
@export var ground_gravity = 9.8      # Gravity when on seabed
@export var air_gravity = 20.0       # Gravity when above water

@export_group("Camera & Orientation")
@export var mouse_sensitivity = 0.003
@export var gamepad_sensitivity = 2.0  # Controller right stick sensitivity
@export var max_pitch = 80.0           # Prevent camera from flipping completely
@export var camera_follow_speed = 5.0  # How smoothly camera follows turtle position
@export var camera_distance = 5.0      # Distance behind turtle
@export var gimbal_lock_prevention = true  # Enable enhanced gimbal lock prevention

@export_group("Turtle Behavior")
@export var body_align_speed = 3.0     # How quickly turtle body follows movement
@export var turn_smoothness = 0.2      # Smoothness of direction changes (0-1)
@export var idle_stabilization = 2.0   # How quickly turtle levels out when idle

@export_group("Input Method Detection")
@export var auto_detect_input = true   # Automatically switch between input methods
@export var current_input_method = "mouse"  # "mouse", "gamepad", "touch"

@export_group("Animation")
@export var animation_player: AnimationPlayer  # Drag your AnimationPlayer node here
@export var animation_blend_time = 0.3         # Time to blend between animations

@export_group("State Detection")
@export var seabed_detection_area: Area3D      # Area3D that triggers seabed state
@export var vertical_velocity_threshold = -0.5 # Downward velocity needed to consider landing

# === NODES ===
# Expected scene structure:
# SeaTurtle (CharacterBody3D) - this script
# ├── TurtleMesh (MeshInstance3D) - your turtle model
# ├── CollisionShape3D - turtle collision
# ├── CameraGimbal (Node3D) - outer gimbal for Y rotation
# │   └── InnerGimbal (Node3D) - inner gimbal for X rotation
# │       └── SpringArm3D
# │           └── Camera3D
# └── AnimationPlayer - turtle animations
# └── SeabedDetector (Area3D) - optional, for seabed detection
#     └── CollisionShape3D

@onready var camera_gimbal = $CameraGimbal
@onready var inner_gimbal = $CameraGimbal/InnerGimbal
@onready var spring_arm = $CameraGimbal/InnerGimbal/SpringArm3D
@onready var camera = $CameraGimbal/InnerGimbal/SpringArm3D/Camera3D
@onready var turtle_mesh = $TurtleMesh

# === INTERNAL VARIABLES ===
var mouse_captured = true
var desired_swim_direction = Vector3.ZERO
var current_swim_speed = 0.0
var is_near_seabed = false
var current_animation = ""

# Enhanced gimbal lock prevention
var accumulated_pitch = 0.0  # Track total pitch across both gimbals
var gimbal_smoothing = 0.1   # Smoothing factor for gimbal corrections

func _ready():
	# Capture mouse for immersive control
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	
	# Set up camera gimbal
	camera_gimbal.global_position = global_position
	spring_arm.spring_length = camera_distance
	
	# Ensure camera faces -Z (Godot's forward direction)
	camera.transform = Transform3D()
	
	# Connect seabed detection if area is assigned
	if seabed_detection_area:
		seabed_detection_area.body_entered.connect(_on_seabed_entered)
		seabed_detection_area.body_exited.connect(_on_seabed_exited)
	
	# Start with floating idle animation
	_play_animation("float_idle")

func _input(event):
	# Auto-detect input method if enabled
	if auto_detect_input:
		_detect_input_method(event)
	
	# Handle different input methods
	match current_input_method:
		"mouse":
			_handle_mouse_input(event)
		"gamepad":
			pass  # Handled in _physics_process for continuous input
		"touch":
			_handle_touch_input(event)  # Future implementation

func _detect_input_method(event):
	if event is InputEventMouseMotion or event is InputEventMouseButton:
		current_input_method = "mouse"
	elif event is InputEventJoypadButton or event is InputEventJoypadMotion:
		current_input_method = "gamepad"
	elif event is InputEventScreenTouch or event is InputEventScreenDrag:
		current_input_method = "touch"

func _handle_mouse_input(event):
	# Toggle mouse capture with Escape
	if event.is_action_pressed("ui_cancel"):
		_toggle_mouse_capture()
	
	# Handle mouse look - this only affects camera, NOT turtle body
	if event is InputEventMouseMotion and mouse_captured:
		_apply_camera_rotation(event.relative)

func _handle_touch_input(event):
	# Future touch implementation
	pass

func _toggle_mouse_capture():
	mouse_captured = !mouse_captured
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED if mouse_captured else Input.MOUSE_MODE_VISIBLE)

func _apply_camera_rotation(mouse_delta: Vector2):
	if gimbal_lock_prevention:
		_apply_camera_rotation_safe(mouse_delta)
	else:
		_apply_camera_rotation_original(mouse_delta)

func _apply_camera_rotation_safe(mouse_delta: Vector2):
	# Enhanced gimbal lock prevention - simpler approach
	var pitch_delta = -mouse_delta.y * mouse_sensitivity
	var yaw_delta = -mouse_delta.x * mouse_sensitivity
	
	# Calculate what the new pitch would be
	var current_pitch = _calculate_total_pitch()
	var new_pitch = current_pitch + pitch_delta
	
	# Clamp the total pitch to prevent gimbal lock
	new_pitch = clamp(new_pitch, -deg_to_rad(max_pitch), deg_to_rad(max_pitch))
	var clamped_pitch_delta = new_pitch - current_pitch
	
	# Apply horizontal rotation (Y axis) - outer gimbal
	camera_gimbal.rotate_object_local(Vector3.UP, yaw_delta)
	
	# Apply vertical rotation (X axis) - inner gimbal with clamping
	if abs(clamped_pitch_delta) > 0.001:  # Avoid micro-adjustments
		inner_gimbal.rotate_object_local(Vector3.RIGHT, clamped_pitch_delta)

func _apply_camera_rotation_original(mouse_delta: Vector2):
	# Original rotation logic for comparison
	camera_gimbal.rotate_object_local(Vector3.UP, -mouse_delta.x * mouse_sensitivity)
	inner_gimbal.rotate_object_local(Vector3.RIGHT, -mouse_delta.y * mouse_sensitivity)
	inner_gimbal.rotation.x = clamp(inner_gimbal.rotation.x, -deg_to_rad(max_pitch), deg_to_rad(max_pitch))

func _calculate_total_pitch() -> float:
	# Calculate the actual pitch of the camera by looking at its forward vector
	var camera_forward = -camera.global_transform.basis.z
	var horizontal_forward = Vector3(camera_forward.x, 0, camera_forward.z).normalized()
	
	if horizontal_forward.length() < 0.001:
		# Camera is pointing straight up or down
		return sign(camera_forward.y) * deg_to_rad(90)
	
	return asin(clamp(camera_forward.y, -1.0, 1.0))

func _smooth_gimbal_rotations():
	# Removed - was causing unwanted camera rolling
	# The gimbal lock prevention in _apply_camera_rotation_safe is sufficient
	pass

func _physics_process(delta):
	# Update state transition cooldown
	if state_transition_cooldown > 0:
		state_transition_cooldown -= delta
	
	# === HANDLE CONTINUOUS INPUT ===
	_handle_continuous_input(delta)
	
	# === STATE MANAGEMENT ===
	_update_movement_state()
	
	# === SWIMMING/CRAWLING INPUT ===
	var move_input = Input.get_action_strength("move_forward") - Input.get_action_strength("move_backward")
	
	# === FIX: UPDATE THE ANIMATION SPEED VARIABLE HERE ===
	# This variable is now used only to inform the animation system.
	# We use abs() so it works for both forward and backward movement.
	current_swim_speed = abs(move_input)
	
	# === APPLY MOVEMENT BASED ON STATE ===
	match current_state:
		MovementState.FLOATING:
			_handle_floating_movement(move_input, delta)
		MovementState.GROUNDED:
			_handle_grounded_movement(move_input, delta)
	
	# === TURTLE BODY ORIENTATION ===
	_update_turtle_orientation(delta)
	
	# === CAMERA POSITION FOLLOWING ===
	# Camera gimbal smoothly follows turtle position
	var target_position = global_position
	camera_gimbal.global_position = camera_gimbal.global_position.lerp(target_position, camera_follow_speed * delta)
	
	# === APPLY MOVEMENT ===
	move_and_slide()
	
	# === UPDATE ANIMATIONS ===
	_update_animations()

func _update_movement_state():
	# Skip state changes if in cooldown
	if state_transition_cooldown > 0:
		return
	
	var should_be_grounded = false
	
	# Check if we should be grounded
	if is_on_floor():
		should_be_grounded = true
	elif is_near_seabed and velocity.y <= vertical_velocity_threshold:
		should_be_grounded = true
	
	# Change state if needed
	if should_be_grounded and current_state == MovementState.FLOATING:
		_change_state(MovementState.GROUNDED)
	elif not should_be_grounded and current_state == MovementState.GROUNDED:
		_change_state(MovementState.FLOATING)

func _change_state(new_state: MovementState):
	if new_state == current_state:
		return
	
	print("Turtle state changed from ", MovementState.keys()[current_state], " to ", MovementState.keys()[new_state])
	current_state = new_state
	state_transition_cooldown = STATE_TRANSITION_DELAY

func _handle_floating_movement(move_input: float, delta: float):
	# 1. APPLY PLAYER THRUST
	# This force is applied whether in air or water, based on camera direction.
	if move_input > 0.1: # Using a small deadzone
		var camera_forward = -camera.global_transform.basis.z
		var swim_force = camera_forward * swim_power * move_input
		velocity += swim_force * delta
	
	# 2. APPLY ENVIRONMENTAL FORCES (THE CORE OF THE FIX)
	if global_position.y > 0.0:
		# --- WE ARE IN THE AIR ---
		# Apply strong gravity to pull the turtle back down to the water.
		velocity.y -= air_gravity * delta
		
		# Optional: Apply a small amount of air resistance if desired
		# velocity.x *= 0.98
		# velocity.z *= 0.98
		
	else:
		# --- WE ARE UNDERWATER ---
		# Apply water resistance (drag) to the entire velocity vector.
		velocity *= water_resistance

		# Apply gentle buoyancy only when the player is not actively swimming forward.
		# This makes the turtle gently float upwards when idle.
		if move_input < 0.1:
			# We use min() to cap the buoyancy, so the turtle doesn't accelerate upwards forever.
			velocity.y = min(velocity.y + (buoyancy * delta), buoyancy)

	# 3. CAP THE FINAL SPEED
	# This check happens last, after all forces have been applied for the frame.
	if velocity.length() > max_speed:
		velocity = velocity.normalized() * max_speed

func _handle_grounded_movement(move_input: float, delta: float):
	# Apply gravity first.
	velocity.y -= ground_gravity * delta
	
	# Get the camera's forward direction, projected onto the ground plane.
	var camera_forward = -camera.global_transform.basis.z
	var ground_forward = Vector3(camera_forward.x, 0, camera_forward.z).normalized()
	
	# Calculate target velocity based on input.
	var target_velocity = ground_forward * move_input * crawl_power
	
	# Apply the force. We directly manipulate velocity here for a snappy feel.
	velocity.x = target_velocity.x
	velocity.z = target_velocity.z
	
	# Apply ground resistance/friction
	velocity.x *= ground_resistance
	velocity.z *= ground_resistance
	
	# Cap horizontal speed
	var horizontal_velocity = Vector3(velocity.x, 0, velocity.z)
	if horizontal_velocity.length() > ground_max_speed:
		horizontal_velocity = horizontal_velocity.normalized() * ground_max_speed
		velocity.x = horizontal_velocity.x
		velocity.z = horizontal_velocity.z

func _update_turtle_orientation(delta: float):
	# Enhanced turtle body behavior
	if velocity.length() > 0.5:
		# Turtle body smoothly follows its movement direction
		var movement_direction = velocity.normalized()
		
		# In grounded state, keep turtle level with ground
		if current_state == MovementState.GROUNDED:
			movement_direction.y = 0
			movement_direction = movement_direction.normalized()
		
		# Safe looking_at with validation
		var target_transform = _safe_looking_at(global_position, movement_direction, Vector3.UP)
		if target_transform != Transform3D():
			transform = transform.interpolate_with(target_transform, body_align_speed * delta)
	else:
		# When idle, behavior depends on state
		if current_state == MovementState.FLOATING:
			# Gently level out the turtle (realistic floating behavior)
			var current_up = transform.basis.y
			var target_up = Vector3.UP
			var corrected_up = current_up.lerp(target_up, idle_stabilization * delta)
			
			# Maintain forward direction while adjusting up vector
			var forward = -transform.basis.z
			var right = forward.cross(corrected_up).normalized()
			
			# Validate cross product
			if right.length() > 0.001:
				corrected_up = right.cross(forward).normalized()
				transform.basis = Basis(right, corrected_up, -forward)
		elif current_state == MovementState.GROUNDED:
			# Keep turtle level with ground when idle
			var current_forward = -transform.basis.z
			var ground_forward = Vector3(current_forward.x, 0, current_forward.z).normalized()
			if ground_forward.length() > 0.1:
				var target_transform = _safe_looking_at(global_position, ground_forward, Vector3.UP)
				if target_transform != Transform3D():
					transform = transform.interpolate_with(target_transform, idle_stabilization * delta)

func _update_animations():
	var target_animation = ""
	
	# Determine which animation to play based on state and movement
	match current_state:
		MovementState.FLOATING:
			if current_swim_speed > 0.1:
				target_animation = "swim"
			else:
				target_animation = "float_idle"
		MovementState.GROUNDED:
			if current_swim_speed > 0.1:
				target_animation = "crawl"
			else:
				target_animation = "idle"
	
	# Play animation if it's different from current
	if target_animation != current_animation:
		_play_animation(target_animation)

func _play_animation(animation_name: String):
	if not animation_player:
		print("Warning: AnimationPlayer not assigned!")
		return
	
	if not animation_player.has_animation(animation_name):
		print("Warning: Animation '", animation_name, "' not found!")
		return
	
	# Play the animation with blending
	if current_animation != "":
		animation_player.play(animation_name, animation_blend_time)
	else:
		animation_player.play(animation_name)
	
	current_animation = animation_name
	print("Playing animation: ", animation_name)

func _handle_continuous_input(delta):
	# Handle continuous input for gamepads
	if current_input_method == "gamepad":
		_handle_gamepad_input(delta)

func _handle_gamepad_input(delta):
	# Right stick controls camera (look direction)
	var look_input = Vector2(
		Input.get_action_strength("look_right") - Input.get_action_strength("look_left"),
		Input.get_action_strength("look_down") - Input.get_action_strength("look_up")
	)
	
	if look_input.length() > 0.1:  # Deadzone
		_apply_camera_rotation(look_input * gamepad_sensitivity * delta * 100)

# === SEABED DETECTION ===
func _on_seabed_entered(body):
	if body == self:
		is_near_seabed = true
		print("Turtle entered seabed area")

func _on_seabed_exited(body):
	if body == self:
		is_near_seabed = false
		print("Turtle left seabed area")

# === SAFE TRANSFORM HELPERS ===
func _safe_looking_at(origin: Vector3, direction: Vector3, up: Vector3) -> Transform3D:
	# Validate inputs to prevent looking_at errors
	if direction.length() < 0.001:
		# Direction is too small/zero
		return Transform3D()
	
	var target = origin + direction
	
	# Check if origin and target are equal (within tolerance)
	if origin.is_equal_approx(target):
		return Transform3D()
	
	# Check if direction and up are colinear
	var cross_product = direction.cross(up)
	if cross_product.length() < 0.001:
		# Vectors are colinear, use a different up vector
		if abs(direction.y) < 0.9:
			up = Vector3.UP
		else:
			up = Vector3.RIGHT
	
	# Try to create the transform
	var result = Transform3D()
	result.origin = origin
	result = result.looking_at(target, up)
	
	return result

# === HELPER FUNCTIONS ===
func get_swimming_speed() -> float:
	return velocity.length()

func is_actively_swimming() -> bool:
	return current_swim_speed > 0

func get_camera_forward_direction() -> Vector3:
	return -camera.global_transform.basis.z

func get_turtle_forward_direction() -> Vector3:
	return -transform.basis.z

func get_camera_pitch_angle() -> float:
	# Returns the pitch angle in degrees for debugging
	return rad_to_deg(_calculate_total_pitch())

func get_current_state() -> MovementState:
	return current_state

func get_current_state_name() -> String:
	return MovementState.keys()[current_state]

func force_state_change(new_state: MovementState):
	# Force a state change (useful for debugging)
	_change_state(new_state)

func reset_camera_orientation():
	# Utility function to reset camera to neutral position
	camera_gimbal.rotation = Vector3.ZERO
	inner_gimbal.rotation = Vector3.ZERO

func _on_island_area_entered(body):
	if body == self:
		is_near_seabed = true #You can reuse this variable or rename it to is_near_land
		print("Turtle entered island area")

func _on_island_area_exited(body):
	if body == self:
		is_near_seabed = false
		print("Turtle left island area")

# === SCENE SETUP INSTRUCTIONS ===
# 1. Create CharacterBody3D (SeaTurtle)
# 2. Add TurtleMesh (MeshInstance3D) as child
# 3. Add CollisionShape3D as child
# 4. Add CameraGimbal (Node3D) as child
# 5. Add InnerGimbal (Node3D) as child of CameraGimbal
# 6. Add SpringArm3D as child of InnerGimbal
# 7. Add Camera3D as child of SpringArm3D
# 8. Add AnimationPlayer as child
# 9. OPTIONAL: Add SeabedDetector (Area3D) as child with CollisionShape3D
# 10. Set SpringArm3D spring_length to desired camera distance (e.g., 5.0)
# 11. In inspector, assign AnimationPlayer to animation_player export variable
# 12. If using Area3D detection, assign it to seabed_detection_area export variable

# === ANIMATION SETUP ===
# Create these 4 animations in your AnimationPlayer:
# - "float_idle" - Gentle floating motion when idle in water
# - "swim" - Swimming motion when moving in water
# - "idle" - Stationary pose when on seabed
# - "crawl" - Crawling motion when moving on seabed

# === SEABED SETUP ===
# Option 1: Use Area3D detection (recommended)
# - Add Area3D as child of seabed object
# - Set collision layer/mask appropriately
# - Assign to seabed_detection_area in inspector
# 
# Option 2: Use floor detection only
# - Leave seabed_detection_area unassigned
# - State will change based on is_on_floor() only

# === INPUT MAP ===
# Same as before:
# MOUSE/KEYBOARD:
# - "move_forward" (W key)
# - "move_backward" (S key, optional)
# - "ui_cancel" (Escape key)
# 
# GAMEPAD:
# - "move_forward" (Right trigger)
# - "move_backward" (Left trigger, optional)
# - "look_left" (Right stick left)
# - "look_right" (Right stick right)
# - "look_up" (Right stick up)
# - "look_down" (Right stick down)
