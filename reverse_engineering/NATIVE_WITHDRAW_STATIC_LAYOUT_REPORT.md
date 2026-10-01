# NATIVE WITHDRAW STATIC LAYOUT REPORT
**Target Executable**: Total War: WARHAMMER III (`Warhammer3.exe`)
**Mode**: Pure Static Reverse Engineering (Read-Only / No Game Launch / No Runtime Probes / No Guessing)
**Date**: September 29, 2026

---

## 1. Target Executable Identity & Environment

| Property | Value |
| :--- | :--- |
| **File Path** | `C:\Program Files (x86)\Steam\steamapps\common\Total War WARHAMMER III\Warhammer3.exe` |
| **File Size** | `248,173,008` bytes (236.68 MB) |
| **SHA-256** | `6c104a63aacc4d865f78e6d198185f830a43255ae18367ad6be906f5f3433297` |
| **PE Timestamp** | `0x6AB70DA1` |
| **ImageBase** | `0x0000000140000000` |
| **SizeOfImage** | `0x0EF12000` |
| **Primary Code Section** | `.trace` (RVA `0x00001000` - `0x033A4000`, Raw `0x00000400` - `0x033A3400`) |
| **Primary Data Section** | `.edata` (RVA `0x033A4000` - `0x03CE7000`, Raw `0x033A3400` - `0x03CE6400`) |
| **Analysis Tools** | Python 3.13.x, Capstone 5.0.9 x86_64, pefile 2024.8.26, MSVC Dumpbin 14.29.30133 |

---

## 2. Summary of Structure Layout Recovery

| Hierarchy Level | Field / Target | Old Offset / Size | New Offset / Size | Drift | Confidence |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Userdata Wrapper** | `wrapper -> native battle_unit*` | `+0x08` | `+0x08` | `+0x00` (Unchanged) | **VERIFIED** |
| **battle_unit** | `native battle_unit -> unique_ui_id` | `+0x3EA0` | `+0x3EA0` | `+0x00` (Unchanged) | **VERIFIED** |
| **battle_unit** | `native battle_unit -> battle_army*` | `+0x70` | `+0x70` | `+0x00` (Unchanged) | **VERIFIED** |
| **battle_army** | `native battle_army -> BATTLE_SETUP_ALLIANCE*` | `+0x140` | `+0x140` | `+0x00` (Unchanged) | **VERIFIED** |
| **BATTLE_SETUP_ALLIANCE** | `BATTLE_SETUP_ALLIANCE -> can_withdraw` | `+0x240` | `+0x248` | `+0x08` (Shifted +8) | **VERIFIED** |
| **BATTLE_SETUP_ALLIANCE** | `sizeof(BATTLE_SETUP_ALLIANCE)` | `0x388` | `0x390` | `+0x08` (Shifted +8) | **VERIFIED** |

---

## 3. Detailed Per-Field Disassembly & Static Evidence

### FIELD 1: `wrapper -> native battle_unit*`
- **OLD**: `+0x08`
- **NEW**: `+0x08`
- **WIDTH**: 8 bytes (`qword ptr`)
- **ANCHOR**: `battle.unit` Lua method registration table at RVA `0x03D3FD30` (VA: `0x143D3FD30`).
- **EVIDENCE #1 (`battle.unit::unique_ui_id`)**:
  - **Function RVA**: `0x02F18A5C` (VA: `0x142F18A5C`)
  - **Instruction RVA**: `0x02F18A84`
  - **Instruction Bytes**: `48 8B 4E 08`
  - **Assembly**: `mov rcx, qword ptr [rsi + 0x08]`
  - **Pseudocode**: `battle_unit *unit = *(battle_unit**)((char*)wrapper + 0x08);`
- **EVIDENCE #2 (`battle.unit::army`)**:
  - **Function RVA**: `0x02EBE51C` (VA: `0x142EBE51C`)
  - **Instruction RVA**: `0x02EBE539`
  - **Instruction Bytes**: `48 8B 43 08`
  - **Assembly**: `mov rax, qword ptr [rbx + 0x08]`
- **EVIDENCE #3 (`battle.unit::type`)**:
  - **Function RVA**: `0x02F184C8` (VA: `0x142F184C8`)
  - **Instruction RVA**: `0x02F184ED`
  - **Instruction Bytes**: `48 8B 4F 08`
  - **Assembly**: `mov rcx, qword ptr [rdi + 0x08]`
- **CROSS-CHECK**:
  - In `battle.unit::army` (`0x02EBE51C`), creating the returned `battle.army` userdata allocates a 16-byte (`0x10`) wrapper:
    ```asm
    0x02EBE53D: mov  ecx, 0x10             ; sizeof wrapper = 16 bytes
    0x02EBE542: mov  rdi, qword ptr [rax + 0x70] ; battle_army*
    0x02EBE546: call 0x4df230             ; operator new
    0x02EBE551: lea  rax, [rip + 0x880af0] ; vtable
    0x02EBE560: mov  qword ptr [rbx], rax  ; wrapper[0] = vtable
    0x02EBE572: mov  qword ptr [rbx + 8], rdi ; wrapper[+0x08] = native battle_army*
    ```
  - Standard CA engine convention: all Lua battle userdata objects are 16 bytes: `+0x00 vtable`, `+0x08 native pointer`.
- **CONFIDENCE**: **VERIFIED**

---

### FIELD 2: `native battle_unit -> unique_ui_id`
- **OLD**: `+0x3EA0`
- **NEW**: `+0x3EA0`
- **WIDTH**: 4 bytes (`dword ptr` / `uint32`)
- **ANCHOR**: `battle.unit::unique_ui_id` registered in table at RVA `0x03D3FD30`.
- **EVIDENCE**:
  - **Function RVA**: `0x02F18A5C` (VA: `0x142F18A5C`)
  - **Instruction RVA**: `0x02F18A88`
  - **Instruction Bytes**: `8B 91 A0 3E 00 00`
  - **Assembly**: `mov edx, dword ptr [rcx + 0x3ea0]`
  - **Decompiler Pseudocode**:
    ```c
    int __fastcall battle_unit_unique_ui_id_lua(lua_State *L, void *wrapper) {
        battle_unit *unit = *(battle_unit**)((char*)wrapper + 0x08);
        unsigned int uid = *(unsigned int*)((char*)unit + 0x3EA0);
        lua_pushinteger(L, uid);
        return 1;
    }
    ```
- **CROSS-CHECK**:
  - Instruction at `0x02F18A8E: mov rcx, rbx` loads `lua_State*`, followed immediately by `0x02F18A91: call 0x135b848` (`lua_pushinteger`), returning `1` (`0x02F18A9B: mov eax, 1`).
- **CONFIDENCE**: **VERIFIED**

---

### FIELD 3: `native battle_unit -> battle_army`
- **OLD**: `+0x70`
- **NEW**: `+0x70`
- **WIDTH**: 8 bytes (`qword ptr`)
- **ANCHOR**: `battle.unit::army` Lua binding at RVA `0x02EBE51C`.
- **EVIDENCE #1 (`battle.unit::army`)**:
  - **Function RVA**: `0x02EBE51C` (VA: `0x142EBE51C`)
  - **Instruction RVA**: `0x02EBE542`
  - **Instruction Bytes**: `48 8B 78 70`
  - **Assembly**: `mov rdi, qword ptr [rax + 0x70]`
- **EVIDENCE #2 (`unit_can_withdraw` reader)**:
  - **Function RVA**: `0x0301ADA8` (VA: `0x14301ADA8`)
  - **Instruction RVA**: `0x0301ADF1`
  - **Instruction Bytes**: `48 8B 43 70`
  - **Assembly**: `mov rax, qword ptr [rbx + 0x70]`
- **EVIDENCE #3 (`withdraw_validator`)**:
  - **Function RVA**: `0x02D4CA6C` (VA: `0x142D4CA6C`)
  - **Instruction RVA**: `0x02D4CA7B`
  - **Instruction Bytes**: `4C 8B 42 70`
  - **Assembly**: `mov r8, qword ptr [rdx + 0x70]`
- **CONFIDENCE**: **VERIFIED**

---

### FIELD 4: `native battle_army -> BATTLE_SETUP_ALLIANCE`
- **OLD**: `+0x140`
- **NEW**: `+0x140`
- **WIDTH**: 8 bytes (`qword ptr`)
- **ANCHOR**: Native unit Withdraw predicate and order validator.
- **EVIDENCE #1 (`unit_can_withdraw` reader)**:
  - **Function RVA**: `0x0301ADA8` (VA: `0x14301ADA8`)
  - **Instruction RVA**: `0x0301ADF5`
  - **Instruction Bytes**: `48 8B 88 40 01 00 00`
  - **Assembly**: `mov rcx, qword ptr [rax + 0x140]`
  - **Context**: `rax` holds `battle_army*` loaded from `[rbx + 0x70]`.
- **EVIDENCE #2 (`withdraw_validator`)**:
  - **Function RVA**: `0x02D4CA6C` (VA: `0x142D4CA6C`)
  - **Instruction RVA**: `0x02D4CA7F`
  - **Instruction Bytes**: `49 8B 80 40 01 00 00`
  - **Assembly**: `mov rax, qword ptr [r8 + 0x140]`
  - **Context**: `r8` holds `battle_army*` loaded from `[rdx + 0x70]`.
- **EVIDENCE #3 (`army_can_withdraw` alliance unit iterator)**:
  - **Function RVA**: `0x02D7A97C` (VA: `0x142D7A97C`)
  - **Instruction RVA**: `0x02D7A9BE`
  - **Instruction Bytes**: `48 8B 88 40 01 00 00`
  - **Assembly**: `mov rcx, qword ptr [rax + 0x140]`
- **CONFIDENCE**: **VERIFIED**

---

### FIELD 5: `BATTLE_SETUP_ALLIANCE -> can_withdraw`
- **OLD**: `+0x240`
- **NEW**: `+0x248`
- **WIDTH**: 1 byte (`uint8` / `byte ptr`)
- **DRIFT**: Exactly `+0x08` bytes (matches the `+0x08` growth of `sizeof(BATTLE_SETUP_ALLIANCE)`).

#### Writer / Serializer
- **Function RVA**: `0x02D1B434` (VA: `0x142D1B434`)
- **Instruction RVA**: `0x02D1CC42`
- **Instruction Bytes**: `88 87 48 02 00 00`
- **Assembly**: `mov byte ptr [rdi + 0x248], al`
- **Semantic Anchor**: Directly follows serialization/XML string lookup for UTF-16LE `"can_withdraw"` (`0x143900228`):
  ```asm
  0x02D1CBED: lea rdx, [rip + 0xbe3634]   ; L"can_withdraw"
  ...
  0x02D1CC1B: lea rdx, [rip + 0xbe3606]   ; L"can_withdraw"
  ...
  0x02D1CC3D: call 0x5a1a2c              ; parse boolean value
  0x02D1CC42: mov  byte ptr [rdi + 0x248], al ; store into setup_alliance->can_withdraw
  ```

#### Default Initializer / Constructor
- **Function RVA**: `0x02D1B434` (VA: `0x142D1B434`)
- **Instruction RVA**: `0x02D1B696`
- **Instruction Bytes**: `44 88 AF 48 02 00 00`
- **Assembly**: `mov byte ptr [rdi + 0x248], r13b` (`r13b = 0`, sets default to `false`).

#### Reader #1: Per-Unit Withdraw Capability (`unit_can_withdraw`)
- **Function RVA**: `0x0301ADA8` (VA: `0x14301ADA8`)
- **Instruction RVA**: `0x0301ADFC`
- **Instruction Bytes**: `8A 81 48 02 00 00`
- **Assembly**: `mov al, byte ptr [rcx + 0x248]`
- **Full Sequence**:
  ```asm
  0x0301ADF1: mov rax, qword ptr [rbx + 0x70]       ; battle_unit -> battle_army*
  0x0301ADF5: mov rcx, qword ptr [rax + 0x140]      ; battle_army -> BATTLE_SETUP_ALLIANCE*
  0x0301ADFC: mov al, byte ptr [rcx + 0x248]        ; setup_alliance -> can_withdraw
  0x0301AE02: add rsp, 0x20
  0x0301AE06: pop rbx
  0x0301AE07: ret
  ```

#### Reader #2: Native Withdraw Command Validator
- **Function RVA**: `0x02D4CA6C` (VA: `0x142D4CA6C`)
- **Instruction RVA**: `0x02D4CA86`
- **Instruction Bytes**: `80 B8 48 02 00 00 00`
- **Assembly**: `cmp byte ptr [rax + 0x248], 0`
- **Full Sequence**:
  ```asm
  0x02D4CA7B: mov r8, qword ptr [rdx + 0x70]        ; unit -> army
  0x02D4CA7F: mov rax, qword ptr [r8 + 0x140]       ; army -> setup alliance
  0x02D4CA86: cmp byte ptr [rax + 0x248], 0         ; can_withdraw == 0?
  0x02D4CA8D: jne 0x2d4ca93                         ; if != 0, continue validation
  0x02D4CA8F: xor al, al                            ; if == 0, reject command (return false)
  0x02D4CA91: jmp 0x2d4cad6
  ```

#### Reader #3: Alliance-Wide Withdraw Check
- **Function RVA**: `0x02D7A97C` (VA: `0x142D7A97C`)
- **Instruction RVA**: `0x02D7A9C5`
- **Instruction Bytes**: `80 B9 48 02 00 00 00`
- **Assembly**: `cmp byte ptr [rcx + 0x248], 0`
- **Context**: Iterates over units in alliance army list, checking if alliance permits withdraw before executing withdraw order batch.

#### UI Relation
- UI availability state queries `unit_can_withdraw` (RVA `0x0301ADA8`), which reads `[setup + 0x248]`. When `0`, the game engine disables the Withdraw button.
- When modified to `1`, the native UI state machinery enables the native Withdraw button (`button_withdraw`).

#### Withdraw Validator Relation
- The native command validation function at `0x02D4CA6C` explicitly tests `cmp byte ptr [rax + 0x248], 0`.
- If `[rax + 0x248] == 0`, it unconditionally returns `0` (`al = 0`), rejecting any incoming CA Withdraw order even if the UI button was forced visible.
- Changing `[setup + 0x248]` to `1` satisfies both the UI and the command validator simultaneously.
- **CONFIDENCE**: **VERIFIED**

---

### FIELD 6: `sizeof(BATTLE_SETUP_ALLIANCE)`
- **OLD**: `0x388` (904 bytes)
- **NEW**: `0x390` (912 bytes)
- **DRIFT**: Exactly `+8` bytes.
- **EVIDENCE**:
  - Found in `std::vector<BATTLE_SETUP_ALLIANCE>::push_back` / vector resize implementation:
    - **Function RVA**: `0x021923A4` (VA: `0x1421923A4`)
    - **Instruction RVA 0x021923E6**: `48 69 C8 90 03 00 00` -> `imul rcx, rax, 0x390`
    - **Instruction RVA 0x021923F8**: `48 69 C9 90 03 00 00` -> `imul rcx, rcx, 0x390`
    - **Instruction RVA 0x02192415**: `41 BF 90 03 00 00`    -> `mov r15d, 0x390`
    - **Instruction RVA 0x0219241B**: `4C 69 F0 90 03 00 00` -> `imul r14, rax, 0x390`
    - **Instruction RVA 0x02192443**: `48 69 D8 90 03 00 00` -> `imul rbx, rax, 0x390`
    - **Instruction RVA 0x02192476**: `48 69 C8 90 03 00 00` -> `imul rcx, rax, 0x390`
    - **Instruction RVA 0x0219249A**: `48 69 C8 90 03 00 00` -> `imul rcx, rax, 0x390`
    - **Instruction RVA 0x021924A5**: `48 05 70 FC FF FF`    -> `add rax, -0x390`
- **CONFIDENCE**: **VERIFIED**

---

## 4. Architectural Coherence Proof

1. `sizeof(BATTLE_SETUP_ALLIANCE)` increased by exactly **8 bytes** (`0x388 -> 0x390`).
2. `can_withdraw` displacement increased by exactly **8 bytes** (`0x240 -> 0x248`).
3. All intermediate pointer offsets (`wrapper -> +0x08`, `unit -> army: +0x70`, `unit -> uid: +0x3EA0`, `army -> setup: +0x140`) remain **100% stable and unchanged**.
4. Both native readers (`unit_can_withdraw` and `withdraw_validator`) converge on displacement `+0x248` as a 1-byte read.
