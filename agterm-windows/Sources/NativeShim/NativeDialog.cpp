#include "NativeShim.h"
#include "NativeChrome.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commctrl.h>

namespace {

using TaskDialogIndirectFn = HRESULT(WINAPI *)(const TASKDIALOGCONFIG *, int *, int *, BOOL *);

constexpr char commonControls6[] =
    "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
    "<assembly xmlns=\"urn:schemas-microsoft-com:asm.v1\" manifestVersion=\"1.0\"><dependency><dependentAssembly>"
    "<assemblyIdentity type=\"win32\" name=\"Microsoft.Windows.Common-Controls\" version=\"6.0.0.0\" processorArchitecture=\"*\""
    " publicKeyToken=\"6595b64144ccf1df\" language=\"*\"/></dependentAssembly></dependency></assembly>";

// append copies `text` onto the end of `buffer`, of `capacity` units, cutting it short rather than overflowing; no STL,
// which windows-11-arm's Visual Studio refuses with this clang (windows.yml).
void append(wchar_t *buffer, size_t capacity, const wchar_t *text) {
    size_t length = lstrlenW(buffer);
    while (*text && length + 1 < capacity) buffer[length++] = *text++;
    buffer[length] = 0;
}

}  // namespace

// TaskDialogIndirect and the themed controls are only in comctl32 6, which agterm-win's manifest-less executable never
// loads by default: an activation context from a manifest naming it loads that version beside the default one.
HANDLE nt_common_controls_context() {
    static HANDLE context = [] {
        static wchar_t path[MAX_PATH];
        DWORD length = GetTempPathW(MAX_PATH, path);
        if (length == 0 || length >= MAX_PATH - 32) return INVALID_HANDLE_VALUE;
        append(path, MAX_PATH, L"agterm-comctl6.manifest");
        HANDLE file = CreateFileW(path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE) return INVALID_HANDLE_VALUE;
        DWORD written = 0;
        BOOL wrote = WriteFile(file, commonControls6, sizeof(commonControls6) - 1, &written, nullptr);
        CloseHandle(file);
        if (!wrote) return INVALID_HANDLE_VALUE;
        ACTCTXW request{};
        request.cbSize = sizeof(request);
        request.lpSource = path;
        return CreateActCtxW(&request);
    }();
    return context;
}

extern "C" int32_t nt_ask_choice(void *owner, const uint16_t *caption, const uint16_t *instruction, const uint16_t *content,
                                 const uint16_t *const *buttons, int32_t count) {
    auto text = [](const uint16_t *value) { return reinterpret_cast<const wchar_t *>(value); };
    HANDLE context = nt_common_controls_context();
    ULONG_PTR cookie = 0;
    bool active = context != INVALID_HANDLE_VALUE && ActivateActCtx(context, &cookie);
    HMODULE comctl = active ? LoadLibraryW(L"comctl32.dll") : nullptr;
    auto show = comctl ? reinterpret_cast<TaskDialogIndirectFn>(GetProcAddress(comctl, "TaskDialogIndirect")) : nullptr;
    int32_t result = -1;
    if (show) {
        TASKDIALOG_BUTTON items[8];
        int32_t shown = count < 8 ? count : 8;
        for (int32_t index = 0; index < shown; ++index) items[index] = {100 + index, text(buttons[index])};
        TASKDIALOGCONFIG config{};
        config.cbSize = sizeof(config);
        config.hwndParent = static_cast<HWND>(owner);
        // no TDF_ALLOW_DIALOG_CANCELLATION: no close button and no Esc, so the dialog ends only on a button
        config.dwFlags = TDF_USE_COMMAND_LINKS | TDF_POSITION_RELATIVE_TO_WINDOW;
        config.pszWindowTitle = text(caption);
        config.pszMainInstruction = text(instruction);
        config.pszContent = text(content);
        config.cButtons = static_cast<UINT>(shown);
        config.pButtons = items;
        config.nDefaultButton = 100;
        int picked = 0;
        if (SUCCEEDED(show(&config, &picked, nullptr, nullptr)) && picked >= 100 && picked < 100 + shown) result = picked - 100;
    }
    if (active) DeactivateActCtx(0, cookie);
    if (result >= 0) return result;
    // comctl32 5: Yes, No and Cancel stand for the first three buttons, named in the text
    if (count < 3) return 0;
    wchar_t body[2048] = {};
    const wchar_t *parts[] = {text(instruction), L"\n\n", text(content), L"\n\nYes: ", text(buttons[0]), L"\nNo: ", text(buttons[1]),
                              L"\nCancel: ", text(buttons[2])};
    for (const wchar_t *part : parts) append(body, sizeof(body) / sizeof(body[0]), part);
    switch (MessageBoxW(static_cast<HWND>(owner), body, text(caption), MB_YESNOCANCEL | MB_ICONQUESTION)) {
    case IDYES: return 0;
    case IDNO: return 1;
    default: return 2;
    }
}
