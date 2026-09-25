"""Run host-independent Luau/Lua tests using the system Lua 5.4 library."""
import ctypes
import ctypes.util
import pathlib
import unittest


class LlmBackendTests(unittest.TestCase):
    def test_provider_and_service_contracts(self):
        library = ctypes.util.find_library("lua5.4")
        if not library:
            self.skipTest("requires liblua5.4")
        lua = ctypes.CDLL(library)
        lua.luaL_newstate.restype = ctypes.c_void_p
        lua.luaL_openlibs.argtypes = [ctypes.c_void_p]
        lua.luaL_loadstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        lua.lua_pcallk.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int,
                                 ctypes.c_int, ctypes.c_ssize_t, ctypes.c_void_p]
        lua.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
        lua.lua_tolstring.restype = ctypes.c_char_p
        lua.lua_close.argtypes = [ctypes.c_void_p]
        state = lua.luaL_newstate()
        try:
            lua.luaL_openlibs(state)
            path = pathlib.Path(__file__).resolve().parent
            script = f'assert(loadfile([[{path}/test_llm_backend.luau]]))([[{path}]])'
            status = lua.luaL_loadstring(state, script.encode())
            if not status:
                status = lua.lua_pcallk(state, 0, 0, 0, 0, None)
            error = lua.lua_tolstring(state, -1, None) if status else b""
            self.assertEqual(0, status, error.decode(errors="replace"))
        finally:
            lua.lua_close(state)


if __name__ == "__main__":
    unittest.main()
