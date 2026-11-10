#pragma once
#include <cstdint>
// Fake clock: advances 1 ms per call.
inline int64_t esp_timer_get_time() { static int64_t t = 6000000; t += 1000; return t; }
