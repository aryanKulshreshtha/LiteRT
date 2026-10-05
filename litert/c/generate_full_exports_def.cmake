# Aggregates every .obj file under OBJDIRS (a ;-separated list of the
# CMakeFiles/<target>.dir directories for litert_c_api, litert_runtime, and
# litert_cc_internal) into one object-list file, then runs CMake's own
# `-E __create_def` helper over it to produce a single exports.def covering
# the full LiteRT C API surface. tensorflow-lite's own objects are
# deliberately excluded -- those are internal implementation details, not
# part of the public C API, and exporting them would bloat the DLL and risk
# ODR/symbol clashes with other DLLs in the same process that link their own
# copy of TFLite/Abseil.
#
# Expected -D variables: OBJDIRS, OUT_DEF, OUT_OBJLIST, NM, CMAKE_COMMAND_PATH

set(_all_objs)
foreach(_dir IN LISTS OBJDIRS)
  file(GLOB_RECURSE _objs "${_dir}/*.obj")
  list(APPEND _all_objs ${_objs})
endforeach()

list(LENGTH _all_objs _obj_count)
if(_obj_count EQUAL 0)
  message(FATAL_ERROR "generate_full_exports_def: found no .obj files under: ${OBJDIRS}")
endif()

file(WRITE "${OUT_OBJLIST}" "")
foreach(_obj IN LISTS _all_objs)
  file(APPEND "${OUT_OBJLIST}" "${_obj}\n")
endforeach()

set(_raw_def "${OUT_DEF}.raw")
execute_process(
    COMMAND "${CMAKE_COMMAND_PATH}" -E __create_def "${_raw_def}" "${OUT_OBJLIST}" --nm=${NM}
    RESULT_VARIABLE _rv
)
if(NOT _rv EQUAL 0)
  message(FATAL_ERROR "generate_full_exports_def: __create_def failed (${_rv}) over ${_obj_count} objects")
endif()

# nm's COFF parsing surfaces the entire externally-linked C++ symbol table
# (RTTI, vtables, template instantiations, ~13k entries), most of which
# isn't the public C API and some of which (COMDAT "pick any" template
# instantiations nm doesn't fully understand) isn't even reliably resolvable
# when forced into an export table, causing LNK2001 unresolved externals.
# Keep only the actual LiteRt C API surface.
file(STRINGS "${_raw_def}" _raw_lines)
list(LENGTH _raw_lines _raw_line_count)
set(_kept_lines "EXPORTS")
set(_kept_count 0)
foreach(_line IN LISTS _raw_lines)
  # LiteRt*/kLiteRt* is the main C API; Lrt* is the short-form naming used
  # by the vendor-options C API (LrtCreateGoogleTensorOptions,
  # LrtGetOpaqueCpuOptionsData, etc.) -- a separate, narrower prefix that
  # the main filter doesn't catch. GetLiteRtRuntimeBuiltin is a one-off
  # accessor that doesn't follow either prefix convention.
  if(_line MATCHES "^[ \t]*(LiteRt|kLiteRt|Lrt)[A-Za-z0-9_]*([ \t]|$)" OR
     _line MATCHES "^[ \t]*(TfLiteXNNPackDelegateOptionsDefault|GetLiteRtRuntimeBuiltin)([ \t]|$)")
    list(APPEND _kept_lines "${_line}")
    math(EXPR _kept_count "${_kept_count} + 1")
  endif()
endforeach()
list(JOIN _kept_lines "\n" _kept_content)
file(WRITE "${OUT_DEF}" "${_kept_content}\n")

message(STATUS "generate_full_exports_def: kept ${_kept_count} LiteRt/kLiteRt symbols (out of ${_raw_line_count} raw) from ${_obj_count} objects -> ${OUT_DEF}")
