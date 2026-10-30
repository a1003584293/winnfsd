#include <string>
#include <stdio.h>
#include <sys/stat.h>
#include <windows.h>

bool _utf8_to_wide(const char* s, std::wstring& result);
bool _wide_to_utf8(const wchar_t* s, std::string& result);
FILE* _fsopen_utf8(const char* path, const char* mode, int share);
int _access_utf8(const char* path, int mode);
int _chmod_utf8(const char* path, int mode);
int _mkdir_utf8(const char* path);
int _stat_utf8(const char* path, struct _stat* data);
DWORD _get_file_attributes_utf8(const char* path);
HANDLE _create_file_utf8(const char* path, DWORD access, DWORD share, LPSECURITY_ATTRIBUTES security,
	DWORD creation, DWORD flags, HANDLE templateFile);
