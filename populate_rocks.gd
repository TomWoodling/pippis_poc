extends MultiMeshInstance3D

@export var scatter_radius = 125.0
@export var density = 0.5

func _ready():
	# This script will randomly place the meshes within a radius.
	multimesh.instance_count = int(scatter_radius * density)
	for i in range(multimesh.instance_count):
		var position = Vector3(randf_range(-scatter_radius, scatter_radius), 1, randf_range(-scatter_radius, scatter_radius))
		var rotation = Vector3(randf_range(0, 360), randf_range(0, 360), randf_range(0, 360))
		var scale = Vector3.ONE * randf_range(0.5, 2.5)
		
		var transform = Transform3D(Basis.from_euler(rotation), position)
		transform = transform.scaled(scale)
		
		multimesh.set_instance_transform(i, transform)
