APP_STL := c++_shared

# Observed with the pinned NDK r26b / LLD 17.0.2 Windows build: SHA-1 build
# IDs differed across otherwise byte-identical clean links.
# Omitting the note keeps the packaged AAR reproducible; release symbols remain
# addressable by the separately locked library hash and unstripped build output.
APP_LDFLAGS += -Wl,--build-id=none
