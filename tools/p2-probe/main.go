package main

/*
#include <stdint.h>
static int32_t probe_add(int32_t a, int32_t b) {
	return a + b;
}
*/
import "C"

import "fmt"

//export ProbeHello
func ProbeHello() *C.char {
	return C.CString("hello from openharmony go")
}

//export ProbeAdd
func ProbeAdd(a C.int32_t, b C.int32_t) C.int32_t {
	return C.probe_add(a, b)
}

func main() {
	fmt.Println("p2 probe: c-shared build check")
}
