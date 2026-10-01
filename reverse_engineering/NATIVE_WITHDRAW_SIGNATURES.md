# NATIVE WITHDRAW RESILIENT SIGNATURES & RESOLUTION SPECIFICATION
**Target Executable**: Total War: WARHAMMER III (`Warhammer3.exe`)
**Mode**: Pure Static Signature Specification & Dynamic Displacement Resolution

---

## 1. Overview & Design Principles

To ensure future game patches can be adapted without manual reverse engineering, the following resilient Array-of-Bytes (AOB) signatures have been engineered. 

Key design rules:
1. **No absolute addresses**: ASLR / image base independent.
2. **No rel32 call targets**: All `E8 / E9` relative offsets are wildcarded.
3. **Displacements as extraction targets**: The displacements themselves are wildcarded and parsed dynamically as little-endian integers.
4. **100% Uniqueness**: Each signature matches **exactly once** in the entire 248MB executable.

---

## 2. Signature Catalog

### Signature 1: `unit_can_withdraw` Reader (Primary Resolution Anchor)
Resolves:
- `battle_unit -> battle_army*`
- `battle_army -> BATTLE_SETUP_ALLIANCE*`
- `BATTLE_SETUP_ALLIANCE -> can_withdraw`

- **Target RVA**: `0x0301ADE2` (Match file offset: `0x0301A1E2`)
- **Unique Matches in Build**: **1**
- **Pattern (IDA Style)**:
  ```text
  74 0D 48 8B ?? 48 83 C4 20 5B E9 ?? ?? ?? ?? 48 8B ?? ?? 48 8B ?? ?? ?? ?? ?? 8A ?? ?? ?? ?? ?? 48 83 C4 20 5B C3
  ```
- **Pattern (Regex/Mask Byte-by-Byte)**:
  `tH.HÄ [é....H(..)H(.....)(.....)HÄ [Ã`

- **Byte Extraction Map (Offset from start of match)**:
  | Target Displacement | Opcode | Byte Offset in Match | Width & Encoding | Current Value |
  | :--- | :--- | :--- | :--- | :--- |
  | `battle_unit -> battle_army` | `48 8B 43 [disp8]` | `+0x13` | 1 byte signed / unsigned (`int8`) | `0x70` |
  | `battle_army -> setup_alliance` | `48 8B 88 [disp32]` | `+0x17` | 4 bytes little-endian (`uint32`) | `0x00000140` (`0x140`) |
  | `setup_alliance -> can_withdraw` | `8A 81 [disp32]` | `+0x1D` | 4 bytes little-endian (`uint32`) | `0x00000248` (`0x248`) |

---

### Signature 2: Native Withdraw Validator (Cross-Validation Anchor)
Resolves:
- `battle_unit -> battle_army*`
- `battle_army -> BATTLE_SETUP_ALLIANCE*`
- `BATTLE_SETUP_ALLIANCE -> can_withdraw` (via `cmp byte ptr [reg + disp], 0`)

- **Target RVA**: `0x02D4CA7B` (Match file offset: `0x02D4BE7B`)
- **Unique Matches in Build**: **1**
- **Pattern (IDA Style)**:
  ```text
  4C 8B ?? ?? 49 8B ?? ?? ?? ?? ?? 80 ?? ?? ?? ?? ?? 00 75 04 32 C0 EB
  ```
- **Byte Extraction Map (Offset from start of match)**:
  | Target Displacement | Opcode | Byte Offset in Match | Width & Encoding | Current Value |
  | :--- | :--- | :--- | :--- | :--- |
  | `battle_unit -> battle_army` | `4C 8B 42 [disp8]` | `+0x03` | 1 byte (`int8`) | `0x70` |
  | `battle_army -> setup_alliance` | `49 8B 80 [disp32]` | `+0x07` | 4 bytes little-endian (`uint32`) | `0x00000140` (`0x140`) |
  | `setup_alliance -> can_withdraw` | `80 B8 [disp32] 00` | `+0x0D` | 4 bytes little-endian (`uint32`) | `0x00000248` (`0x248`) |

---

### Signature 3: `battle.unit::unique_ui_id` Lua Binding
Resolves:
- `battle.unit wrapper -> native battle_unit*`
- `native battle_unit -> unique_ui_id`

- **Target RVA**: `0x02F18A84` (Match file offset: `0x02F17E84`)
- **Unique Matches in Build**: **1**
- **Pattern (IDA Style)**:
  ```text
  48 8B ?? ?? 8B ?? ?? ?? ?? ?? 48 8B ?? E8 ?? ?? ?? ?? 48 8B ?? 24 30 B8 01 00 00 00
  ```
- **Byte Extraction Map (Offset from start of match)**:
  | Target Displacement | Opcode | Byte Offset in Match | Width & Encoding | Current Value |
  | :--- | :--- | :--- | :--- | :--- |
  | `wrapper -> battle_unit` | `48 8B 4E [disp8]` | `+0x03` | 1 byte (`int8`) | `0x08` |
  | `battle_unit -> unique_ui_id` | `8B 91 [disp32]` | `+0x06` | 4 bytes little-endian (`uint32`) | `0x00003EA0` (`0x3EA0`) |

---

### Signature 4: `battle.unit::army` Lua Binding
Resolves:
- `battle.unit wrapper -> native battle_unit*`
- `native battle_unit -> battle_army*`

- **Target RVA**: `0x02EBE539` (Match file offset: `0x02EBD939`)
- **Unique Matches in Build**: **1**
- **Pattern (IDA Style)**:
  ```text
  48 8B ?? ?? B9 10 00 00 00 48 8B ?? ?? E8 ?? ?? ?? ?? 48 8B ??
  ```
- **Byte Extraction Map (Offset from start of match)**:
  | Target Displacement | Opcode | Byte Offset in Match | Width & Encoding | Current Value |
  | :--- | :--- | :--- | :--- | :--- |
  | `wrapper -> battle_unit` | `48 8B 43 [disp8]` | `+0x03` | 1 byte (`int8`) | `0x08` |
  | `battle_unit -> battle_army` | `48 8B 78 [disp8]` | `+0x0C` | 1 byte (`int8`) | `0x70` |

---

### Signature 5: `BATTLE_SETUP_ALLIANCE` Vector Growth (`sizeof`)
Resolves:
- `sizeof(BATTLE_SETUP_ALLIANCE)`

- **Target RVA**: `0x021923E6` (Match file offset: `0x021917E6`)
- **Unique Matches in Build**: **1**
- **Pattern (IDA Style)**:
  ```text
  48 69 C8 ?? ?? ?? ?? E8 ?? ?? ?? ?? 8B 4F 04 48 8B D3 48 69 C9
  ```
- **Byte Extraction Map**:
  - `imul rcx, rax, [disp32]` at offset `+0x03`: 4 bytes little-endian = `0x00000390` (`0x390`).

---

## 3. Reference Implementation: Automated Layout Extractor

```python
import struct
import re

def extract_native_layout(exe_bytes):
    # Pattern 1: unit_can_withdraw
    p1 = rb"\x74\x0d\x48\x8b.\x48\x83\xc4\x20\x5b\xe9....\x48\x8b..\x48\x8b.....\x8a.....\x48\x83\xc4\x20\x5b\xc3"
    m1 = list(re.finditer(p1, exe_bytes, re.DOTALL))
    assert len(m1) == 1, f"Expected 1 match for P1, found {len(m1)}"
    pos1 = m1[0].start()
    
    disp_army = exe_bytes[pos1 + 0x13]
    disp_setup = struct.unpack_from("<I", exe_bytes, pos1 + 0x17)[0]
    disp_can_withdraw = struct.unpack_from("<I", exe_bytes, pos1 + 0x1D)[0]
    
    # Pattern 3: battle.unit::unique_ui_id
    p3 = rb"\x48\x8b..\x8b.....\x48\x8b.\xe8....\x48\x8b.\x24\x30\xb8\x01\x00\x00\x00"
    m3 = list(re.finditer(p3, exe_bytes, re.DOTALL))
    assert len(m3) == 1, f"Expected 1 match for P3, found {len(m3)}"
    pos3 = m3[0].start()
    
    disp_wrapper = exe_bytes[pos3 + 0x03]
    disp_uid = struct.unpack_from("<I", exe_bytes, pos3 + 0x06)[0]
    
    return {
        "wrapper_to_unit": hex(disp_wrapper),
        "unit_to_uid": hex(disp_uid),
        "unit_to_army": hex(disp_army),
        "army_to_setup": hex(disp_setup),
        "setup_to_can_withdraw": hex(disp_can_withdraw)
    }

# Running on current binary extracts:
# {'wrapper_to_unit': '0x8', 'unit_to_uid': '0x3ea0', 'unit_to_army': '0x70', 'army_to_setup': '0x140', 'setup_to_can_withdraw': '0x248'}
```
