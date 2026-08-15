#!/bin/bash
echo "📣 Sending LandingZone rollout notification..."
chmod +x iac_modules/scripts/notifications/notify-landingzone.sh
iac_modules/scripts/notifications/notify-landingzone.sh
