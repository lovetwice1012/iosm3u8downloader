cmake_minimum_required(VERSION 3.22.1)
project(hlsffmpeg LANGUAGES CXX)

add_library(hlsffmpeg SHARED hls_ffmpeg_jni.cpp)
target_compile_features(hlsffmpeg PRIVATE cxx_std_17)
target_compile_options(hlsffmpeg PRIVATE -Wall -Wextra -Werror)
target_link_libraries(hlsffmpeg PRIVATE dl log)
