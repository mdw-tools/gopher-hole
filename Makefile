IMAGE := gopher-hole

# Override: make install INSTALL_DIR=...
INSTALL_DIR := $(CODEPATH)/bin

.PHONY: image verify clean install uninstall

image:
	container build -t $(IMAGE) .

verify:
	./verify.sh

clean:
	container image rm $(IMAGE) 2>/dev/null || true

install:
	mkdir -p $(INSTALL_DIR)
	ln -sf $(CURDIR)/gopher-hole $(INSTALL_DIR)/gopher-hole
	@echo "installed: $(INSTALL_DIR)/gopher-hole -> $(CURDIR)/gopher-hole"
	@case ":$$PATH:" in \
	  *":$(INSTALL_DIR):"*) ;; \
	  *) echo "note: $(INSTALL_DIR) is not on your PATH" ;; \
	esac

uninstall:
	rm -f $(INSTALL_DIR)/gopher-hole
