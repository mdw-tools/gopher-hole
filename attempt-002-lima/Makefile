VM_NAME := gopher-hole
YAML    := gopher-hole.yaml

.PHONY: vm-create vm-destroy vm-start vm-stop vm-ssh vm-status

vm-create:
	limactl create --name=$(VM_NAME) ./$(YAML)
	limactl start $(VM_NAME)

vm-destroy:
	limactl stop $(VM_NAME) --force 2>/dev/null || true
	limactl delete $(VM_NAME) --force 2>/dev/null || true

vm-start:
	limactl start $(VM_NAME)

vm-stop:
	limactl stop $(VM_NAME)

vm-ssh:
	limactl shell $(VM_NAME)

vm-status:
	limactl list $(VM_NAME)
