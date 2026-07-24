IMAGE := gopher-hole

.PHONY: image verify clean

image:
	container build -t $(IMAGE) .

verify:
	./verify.sh

clean:
	container image rm $(IMAGE) 2>/dev/null || true
