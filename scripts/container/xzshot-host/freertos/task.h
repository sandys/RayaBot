#pragma once
// Fake scheduler: a "task" is simply called straight away and returns when it deletes itself.
// Delays return immediately.
typedef unsigned int TickType_t;
typedef void (*TaskFunction_t)(void*);
inline void vTaskDelay(int) {}
inline TickType_t xTaskGetTickCount() { return 0; }
inline int xTaskDelayUntil(TickType_t* wake, TickType_t inc) { *wake += inc; return 1; }
inline void vTaskDelete(void*) {}
inline int xTaskCreate(TaskFunction_t fn, const char*, int, void* arg, int, void*) { fn(arg); return 1; }
