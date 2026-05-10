#!/bin/bash
# Context injection hook — provides current date/time to AI sessions
# Attach to your AI tool's notification/context event.
# Ensures the AI never has to guess what day it is.
echo "Current: $(date +'%Y-%m-%d %H:%M %A')"
