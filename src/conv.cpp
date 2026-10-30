#include <windows.h>
#include "conv.h"
#include <string.h>
#include <io.h>
#include <direct.h>
#include <share.h>
#include <errno.h>

bool _utf8_to_wide(const char* s, std::wstring& result) {
	if (s == NULL) {
		return false;
	}

	int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, NULL, 0);
	if (count == 0) {
		return false;
	}

	std::wstring converted(count, L'\0');
	if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, &converted[0], count) == 0) {
		return false;
	}
	converted.resize(count - 1);
	result.swap(converted);
	return true;
}

bool _wide_to_utf8(const wchar_t* s, std::string& result) {
	if (s == NULL) {
		return false;
	}

	int count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, s, -1, NULL, 0, NULL, NULL);
	if (count == 0) {
		return false;
	}

	std::string converted(count, '\0');
	if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, s, -1, &converted[0], count, NULL, NULL) == 0) {
		return false;
	}
	converted.resize(count - 1);
	result.swap(converted);
	return true;
}

FILE* _fsopen_utf8(const char* path, const char* mode, int share) {
	std::wstring widePath;
	if (!_utf8_to_wide(path, widePath) || mode == NULL) {
		errno = EINVAL;
		return NULL;
	}

	std::wstring wideMode;
	while (*mode != '\0') {
		wideMode.push_back(static_cast<unsigned char>(*mode++));
	}
	return _wfsopen(widePath.c_str(), wideMode.c_str(), share);
}

int _access_utf8(const char* path, int mode) {
	std::wstring widePath;
	if (!_utf8_to_wide(path, widePath)) {
		errno = EINVAL;
		return -1;
	}
	return _waccess(widePath.c_str(), mode);
}

int _chmod_utf8(const char* path, int mode) {
	std::wstring widePath;
	if (!_utf8_to_wide(path, widePath)) {
		errno = EINVAL;
		return -1;
	}
	return _wchmod(widePath.c_str(), mode);
}

int _mkdir_utf8(const char* path) {
	std::wstring widePath;
	if (!_utf8_to_wide(path, widePath)) {
		errno = EINVAL;
		return -1;
	}
	return _wmkdir(widePath.c_str());
}

int _stat_utf8(const char* path, struct _stat* data) {
	std::wstring widePath;
	if (!_utf8_to_wide(path, widePath)) {
		errno = EINVAL;
		return -1;
	}
	return _wstat(widePath.c_str(), data);
}

DWORD _get_file_attributes_utf8(const char* path) {
	std::wstring widePath;
	if (!_utf8_to_wide(path, widePath)) {
		SetLastError(ERROR_NO_UNICODE_TRANSLATION);
		return INVALID_FILE_ATTRIBUTES;
	}
	return GetFileAttributesW(widePath.c_str());
}

HANDLE _create_file_utf8(const char* path, DWORD access, DWORD share, LPSECURITY_ATTRIBUTES security,
	DWORD creation, DWORD flags, HANDLE templateFile) {
	std::wstring widePath;
	if (!_utf8_to_wide(path, widePath)) {
		SetLastError(ERROR_NO_UNICODE_TRANSLATION);
		return INVALID_HANDLE_VALUE;
	}
	return CreateFileW(widePath.c_str(), access, share, security, creation, flags, templateFile);
}
