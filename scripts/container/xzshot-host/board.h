#pragma once
#include "display.h"
class Board {
public:
    static Board& GetInstance() { static Board b; return b; }
    Display* GetDisplay();   // defined in harness.cc
};
