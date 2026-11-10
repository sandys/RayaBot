// Fake sdkconfig for the host test: dev screenshots on, no waiting.
#pragma once
#define CONFIG_XZ_DEV_SERIAL_SCREENSHOT 1
#define CONFIG_XZ_DEV_SCREENSHOT_FIRST_MS 0
#define CONFIG_XZ_DEV_SCREENSHOT_PERIOD_MS 0
#define CONFIG_XZ_DEV_SCREENSHOT_QUALITY 90
// CONFIG_XZ_DEV_SCREENSHOT_COUNT comes from the compiler command line (-D...).
