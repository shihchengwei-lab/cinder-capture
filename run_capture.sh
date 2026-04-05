#!/bin/bash
# Wrapper for Stop hook — launches capture in background and exits immediately
python "C:/Users/Boreas/cinder-capture/capture.py" > /dev/null 2>&1 &
disown
exit 0
