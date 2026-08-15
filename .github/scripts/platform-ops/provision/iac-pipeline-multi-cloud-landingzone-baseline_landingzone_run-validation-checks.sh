#!/bin/bash
echo "⚙️ Running LandingZone baseline validation..."
chmod +x iac_modules/scripts/validation/validate-landingzone.sh
iac_modules/scripts/validation/validate-landingzone.sh ${TF_WORKDIR}
