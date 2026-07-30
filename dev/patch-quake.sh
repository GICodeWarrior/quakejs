#!/bin/sh
#
# REFERENCE ONLY -- not run by the container build.
#
# The pinned ioq3 submodule already carries all of these edits, hand-curated in
# the fork and differing from what this script generates:
#
#   * the script appends -g4 to the INVOKE_RUN=0 link flags; the fork instead
#     carries -g4 in OPTIMIZEVM
#   * SYSC__deps uses 'Con_ToggleConsole_f', without the leading underscore
#   * the QVM target's INVOKE_RUN=0 is deliberately left without LINKABLE
#   * only the client EXPORTED_FUNCTIONS carries the console export
#
# Re-running it would duplicate flags and add exports to targets that were left
# alone on purpose, so Containerfile asserts the tree is already patched instead.
#
# Keep this as documentation of what an unpatched upstream ioq3 needs, e.g. when
# rebasing the fork onto a newer ioquake3. It modifies the working tree in place,
# so run it deliberately and commit the result to the submodule.

# Add -s LINKABLE=1 to SERVER_LDFLAGS. This is necessary to get Emscripten to
# correctly export things via EXPORTED_FUNCTIONS. Without this, we get
# 'unresolved symbol: Com_Printf' and stuff.
sed -i -e 's/INVOKE_RUN=1/& -s LINKABLE=1/' Makefile
sed -i -e 's/INVOKE_RUN=0/& -s LINKABLE=1 -g4/' Makefile

# Export syscall()
sed -i -e "/EXPORTED_FUNCTIONS=/ { s/]/, '_Con_ToggleConsole_f']/ }" Makefile
sed -i -e "/SYSC__deps:/ { s/]/, '_Con_ToggleConsole_f']/ }" code/sys/sys_common.js

# Short-circuit EULA prompt. We accept.
sed -i -e '/PromptEULA: function/ { s/$/ return callback();/ }' code/sys/sys_node.js
