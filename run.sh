#!/bin/bash
# Activates Xcode and sends Cmd+R to build, install, and run on the selected destination.
# First run will prompt for Accessibility permission to allow System Events to send keystrokes.
osascript <<'EOF'
tell application "Xcode" to activate
delay 0.15
tell application "System Events" to keystroke "r" using {command down}
EOF
