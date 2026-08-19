# Acuan Resmi Style Docs – "Doxygen Universal"

Aturan utamanya: Delimiter pake bawaan bahasa, tapi tag & struktur isi wajib pake standar Doxygen (@param, @return, @throw, @see, dll).
Biar otak ga usah gonta-ganti format setiap ganti project.

Kode etik resmi untuk STYLE_GUIDE.md project.

---

## 1. Tag Wajib & Opsional (Standar Doxygen)

Buat semua bahasa, cuma pake tag-tag ini:

| Tag Fitur | Wajib? |
|---|---|
| `@brief` Judul singkat (1 kalimat) | ✅ WAJIB (bisa jadi kalimat pertama) |
| `@param` Deskripsi parameter. Format: `@param {tipe} nama - deskripsi` | ✅ WAJIB kalau ada parameter |
| `@return` / `@returns` Deskripsi nilai balik. Format: `@return {tipe} deskripsi` | ✅ WAJIB kalau ga void |
| `@throw` / `@exception` Error/Exception yang dilempar | ❌ Opsional (kalau ada) |
| `@example` Contoh kode penggunaan | ❌ Opsional (sangat direkomendasikan untuk public API) |
| `@see` Referensi ke fungsi/modul lain | ❌ Opsional |
| `@todo` Catatan yang harus dikerjakan | ❌ Opsional |
| `@deprecated` Tandai fungsi udah usang | ❌ Opsional |
| `@since` Versi dimana fitur ditambahkan | ❌ Opsional |
| `@author` Penulis asli kode | ❌ Opsional |
| `@version` Nomor versi fungsi | ❌ Opsional |
| `@note` Catatan penting tambahan | ❌ Opsional |
| `@warning` Peringatan penting | ❌ Opsional |
| `@attention` Hal yang perlu diperhatikan | ❌ Opsional |
| `@remark` Catatan tambahan yang detail | ❌ Opsional |
| `@invariant` Invariants yang harus terjaga | ❌ Opsional |
| `@pre` Kondisi pre-requisite pemanggilan | ❌ Opsional |
| `@post` Kondisi post-kondisi hasil pemanggilan | ❌ Opsional |
| `@complexity` Kompleksitas waktu/ruang | ❌ Opsional |
| `@threadsafe` Apakah fungsi aman untuk thread | ❌ Opsional |
| `@reentrant` Apakah fungsi reentrant | ❌ Opsional |
| `@security` Catatan keamanan | ❌ Opsional |
| `@deprecated` Pesan usang + alternatif | ❌ Opsional |
| `@copydoc` Salin dokumentasi dari symbol lain | ❌ Opsional |
| `@shortcopyof` Referensi doc singkat | ❌ Opsional |

---

## 2. Mapping Delimiter per Bahasa (Tetep Bawaan)

Kita tetep manut sama syntax bawaan biar IDE & tooling (JSDoc, rustdoc, Sphinx) ga error, tapi isinya seragam:

| Bahasa | Delimiter | Contoh Pembuka |
|---|---|---|
| JavaScript / TypeScript | `/** ... */` | `/**` + Enter |
| Python | `""" ... """` | `"""` + Enter |
| Rust | `/// ...` (atau `/** ... */`) | `///` + Spasi |
| Go | `// ...` | `//` + Spasi |
| Java / Kotlin | `/** ... */` | `/**` + Enter |
| C / C++ | `/* ... */` atau `/// ...` | `/*` + Enter |
| C# | `/// ...` atau `<summary>` XML | `///` + Enter |
| PHP | `/** ... */` (phpDocumentor) atau `#` | `/**` + Enter |
| Ruby | `=begin ... =end` atau RDoc `###` | `###` + Spasi |
| Swift | `/// ...` atau `/** ... */\n - parameter:` | `///` + Spasi |
| Zig | `/// ...` (item) / `//! ...` (file/container) | `///` + Spasi |

---
## 2.1 Komentar Sintaks (Bukan Cuma untuk Dokumentasi)

Selain doc-comment (delimiter di §2), tiap bahasa punya **komentar sintaks biasa** untuk keperluan non-dokumentasi: penjelas logika, marker kerja (`TODO`/`FIXME`/`NOTE`/`HACK`/`XXX`), pemisah section, dan menonaktifkan sementara kode. Aturan:

- **Prefix per bahasa** (baris komentar, BUKAN doc-comment):

| Bahasa | Prefix | Block |
|---|---|---|
| JavaScript / TypeScript | `//` | `/* ... */` |
| Python | `#` | `""" ... """` (multi-line string, bukan comment murni) |
| Rust | `//` | `/* ... */` |
| Go | `//` | `/* ... */` |
| Java / Kotlin | `//` | `/* ... */` |
| C / C++ | `//` | `/* ... */` |
| C# | `//` | `/* ... */` |
| PHP | `//` atau `#` | `/* ... */` |
| Ruby | `#` | `=begin ... =end` |
| Swift | `//` | `/* ... */` |
| Zig | `//` | — (Zig tidak punya block comment) |

- **Marker kerja** wajib kapital + konsisten:
  - `TODO:` pekerjaan belum dibuat.
  - `FIXME:` bug yang harus diperbaiki.
  - `NOTE:` penjelas konteks / keputusan.
  - `HACK:` solusi sementara yang perlu diganti.
  - `XXX:` bahaya / perlu review.
  - Format: `// TODO(user): deskripsi singkat`.
- **Jangan** tulis komentar yang cuma mengulang kode (`i += 1 // tambah i`). Komentar jelaskan **why**, bukan **what**.
- **Nonaktifkan kode**: hindari komen panjang; lebih baik hapus atau andalkan VCS. Kalau terpaksa, tandai `// FIXME: disabled sementara — alasan X`.

---

## 3. Template per Bahasa

### A. JavaScript / TypeScript (JSDoc + Doxygen)

```typescript
/**
 * @brief Mengubah JSON mentah menjadi model Field.
 * @param {object} value - JSON object wajib memiliki key `name`.
 * @param {string} [value.type] - Opsional, default ke string kosong.
 * @param {string} [value.visibility] - Opsional, default 'private'.
 * @return {Field | null} Hasil parsing, atau null kalau name hilang.
 * @throw {TypeError} Kalau value bukan object.
 * @example
 * const field = extractField({ name: 'user_id' });
 * console.log(field?.name); // 'user_id'
 * @see parseVisibility
 * @since 1.2.0
 * @author Tim Backend
 * @group Data Parsing
 * @memberof FieldManager
 * @public
 */
function extractField(value: any): Field | null {
  // ...
}
```

---

### B. Python (Doxygen via Docstring)

```python
def extract_field(value: dict) -> Field | None:
    """Mengubah JSON mentah menjadi model Field.
    
    @param value (dict): JSON object wajib memiliki key `name`.
        Opsional: `type` (default '') dan `visibility` (default 'private').
    @return Field or None: Hasil parsing, atau None kalau name hilang.
    @throw TypeError: Kalau value bukan dict.
    
    @example
        field = extract_field({"name": "user_id"})
        print(field.name) # 'user_id'
    
    @see parse_visibility
    @since 1.2.0
    @author Tim Backend
    @group Data Parsing
    @public
    """
    # ...
```

---

### C. Rust (Rustdoc + Doxygen Tags)

```rust
/// Mengubah JSON mentah menjadi model Field.
///
/// # Arguments
///
/// * `value` - JSON object. Wajib ada key `name`.
///   Opsional: `type` (default "") dan `visibility` (default `Private`).
///
/// # Returns
///
/// `Some(Field)` - Hasil parsing, atau `None` kalau name hilang.
///
/// # Errors
///
/// Fungsi ini tidak akan panic.
///
/// # Examples
///
/// ```
/// let field = extract_field(json!({"name": "user_id"}));
/// assert_eq!(field.unwrap().name, "user_id");
/// ```
///
/// # See Also
///
/// [`parse_visibility`]
///
/// # Since
///
/// 1.2.0
///
/// # Author
///
/// Tim Backend
///
/// # Group
///
/// Data Parsing
#[must_use]
pub fn extract_field(value: &Value) -> Option<Field> {
    // ...
}
```

---

### D. Go (godoc + Doxygen-style tags dalam komentar)

```go
// ExtractField mengubah JSON mentah menjadi model Field.
//
// Parameters:
//   - value: JSON object wajib memiliki key "name".
//     Opsional: "type" (default "") dan "visibility" (default "private").
//
// Returns:
//   - *Field: Hasil parsing, atau nil kalau name hilang.
//   - error: Kalau value bukan object.
//
// Example:
//
//	field, err := ExtractField(map[string]interface{}{"name": "user_id"})
//	if err != nil {
//	    log.Fatal(err)
//	}
//	fmt.Println(field.Name) // "user_id"
//
// See: ParseVisibility
// Since: v1.2.0
// Author: Tim Backend
// Group: Data Parsing
// Public API
func ExtractField(value map[string]interface{}) (*Field, error) {
    // ...
}
```

---

### E. Java / Kotlin (Javadoc + Doxygen-style tags)

```java
/**
 * Mengubah JSON mentah menjadi model Field.
 *
 * @param value JSON object wajib memiliki key {@code "name"}.
 * @param <T>   Tipe generic untuk Field
 * @return {@link Field} hasil parsing, atau {@code null} kalau name hilang.
 * @throws TypeError kalau value bukan object.
 * @since 1.2.0
 * @author Tim Backend
 * @group Data Parsing
 * @see #parseVisibility()
 */
public <T extends Field> Field extractField(Map<String, Object> value) {
    // ...
}
```

```kotlin
/**
 * Mengubah JSON mentah menjadi model Field.
 *
 * @param value JSON object wajib memiliki key `"name"`.
 * @param <T>   Tipe generic untuk Field.
 * @return [Field] hasil parsing, atau `null` kalau name hilang.
 * @throws [TypeError] kalau value bukan object.
 * @since 1.2.0
 * @author Tim Backend
 * @group Data Parsing
 * @see [parseVisibility]
 */
inline fun <reified T : Field> extractField(value: Map<String, Any>): Field? {
    // ...
}
```

---

### F. C# (XML Doc Comments + Doxygen-style tags)

```csharp
/// Mengubah JSON mentah menjadi model Field.
/// 
/// <param name="value">JSON object wajib memiliki key <c>"name"</c>.</param>
/// <typeparam name="T">Tipe generic untuk Field.</typeparam>
/// <return>Hasil parsing, atau <c>null</c> kalau name hilang.</return>
/// <exception cref="TypeError">Kalau value bukan object.</exception>
/// <since>1.2.0</since>
/// <author>Tim Backend</author>
/// <group>Data Parsing</group>
/// <seealso cref="ParseVisibility"/>
public Field? ExtractField<T>(Dictionary<string, object> value) where T : Field {
    // ...
}
```

---

### G. PHP (phpDocumentor + Doxygen-style tags)

```php
/**
 * Mengubah JSON mentah menjadi model Field.
 *
 * @param array<string, mixed> $value JSON object wajib memiliki key "name".
 *     Opsional: "type" (default '') dan "visibility" (default 'private').
 * @return Field|null Hasil parsing, atau null kalau name hilang.
 * @throws TypeError Kalau value bukan array.
 *
 * @example
 * $field = extract_field(["name" => "user_id"]);
 * echo $field->name; // 'user_id'
 *
 * @see parse_visibility()
 * @since 1.2.0
 * @author Tim Backend
 * @group Data Parsing
 * @psalm-immutable
 */
function extract_field(array $value): ?Field {
    // ...
}
```

---

### H. Ruby (RDoc + Doxygen-style tags)

```ruby
# Mengubah JSON mentah menjadi model Field.
#
# @param value [Hash] JSON object wajib memiliki key "name".
#     Opsional: "type" (default nil) dan "visibility" (default "private").
# @return [Field, nil] Hasil parsing, atau nil kalau name hilang.
# @raise TypeError Kalau value bukan Hash.
#
# @example
#   field = extract_field("name" => "user_id")
#   field.name # => "user_id"
#
# @see #parse_visibility
# @since 1.2.0
# @author Tim Backend
# @group Data Parsing
# @public
def extract_field(value)
  # ...
end
```
---

### I. Zig (Zigdoc + Doxygen-style tags)

```zig
/// Mengubah JSON mentah menjadi model Field.
///
/// @param value JSON object wajib memiliki key `name`.
/// @return ?Field Hasil parsing, atau null kalau name hilang.
/// @throw TypeError Kalau value bukan object.
/// @example
/// const field = extractField(.{ .name = "user_id" });
/// std.debug.print("{s}\n", .{field.?.name});
/// @see parseVisibility
/// @since 1.2.0
/// @author Tim Backend
/// @group Data Parsing
pub fn extractField(value: std.json.Value) ?Field {
    // ...
}
```

---

## 4. Doc Konstruktor / Interface / Struct / Class

### A. JavaScript / TypeScript (Interface & Class)

```typescript
/**
 * @brief Representasi Field schema untuk parsing JSON.
 * @description Model internal yang menyimpan metadata field
 *              seperti tipe dan visibility.
 * @interface
 * @group Data Models
 * @public
 * @author Tim Backend
 * @since 1.0.0
 * @see extractField
 * 
 * @property {string} name - Nama field (WAJIB).
 * @property {string} [type="string"] - Tipe data field.
 * @property {string} [visibility="private"] - Level visibility.
 */
interface Field {
  /** Nama unik field dalam parent. */
  name: string;
  /** Tipe data (string, number, boolean, dll). */
  type?: string;
  /** Level visibility: private, protected, public. */
  visibility?: string;
}

/**
 * @brief Manager untuk operasi Field.
 * @class
 * @group Data Parsing
 * @public
 * @abstract
 */
class FieldManager {
  /** @brief Constructor. */
  constructor(private ctx: Context) {}
}
```

---

### B. Python (Class & Dataclass)

```python
class Field:
    """Representasi Field schema untuk parsing JSON.
    
    @brief Model internal untuk metadata field.
    @group Data Models
    @since 1.0.0
    @author Tim Backend
    @abstract
    
    Attributes:
        name (str): Nama field (WAJIB).
        type (str): Tipe data (default: "string").
        visibility (str): Level visibility (default: "private").
    """
    def __init__(self, name: str, type: str = "string", visibility: str = "private") -> None:
        self.name = name
        self.type = type
        self.visibility = visibility
```

---

### C. Rust (Struct + Derive + Module)

```rust
/// Representasi Field schema untuk parsing JSON.
///
/// @brief Model internal untuk metadata field.
/// @group Data Models
/// @since 1.0.0
/// @author Tim Backend
/// 
/// # Fields
///
/// * `name` — Nama unik field dalam parent (WAJIB).
/// * `r#type` — Tipe data (default: "string").
/// * `visibility` — Level visibility (default: Private).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[group = "Data Models"]
pub struct Field {
    /// Nama unik field.
    pub name: String,
    /// Tipe data.
    pub r#type: String,
    /// Level visibility.
    pub visibility: Visibility,
}

impl Field {
    /// Buat Field baru dengan minimal parameter.
    /// 
    /// @brief Constructor statik.
    /// @param name Nama field (WAJIB).
    /// @param type Tipe data (opsional, default "").
    /// @param visibility Visibility (opsional, default Private).
    /// @return Some(Field) kalau valid.
    pub fn new(name: impl Into<String>, r#type: impl Into<String>, visibility: Visibility) -> Self {
        Self { name: name.into(), r#type: r#type.into(), visibility }
    }
}
```

---

### D. Go (Struct + Constructor)

```go
// Field merepresentasikan schema field untuk parsing JSON.
//
// @brief Model internal untuk metadata field.
// @group Data Models
// @since 1.0.0
// @author Tim Backend
//
// Fields:
//   - Name: Nama unik field (WAJIB).
//   - Type: Tipe data (default: "").
//   - Visibility: Level visibility (default: Private).
type Field struct {
    Name       string
    Type       string
    Visibility Visibility
}

// NewField membuat Field baru.
//
// @param name Nama field (WAJIB).
// @param type Tipe data (opsional, default "").
// @param visibility Level visibility (opsional, default Private).
// @return *Field dan error (tidak ada error untuk input valid).
// @public
func NewField(name string, typ string, visibility Visibility) (*Field, error) {
    // ...
}
```

---

### E. Java (Class + Records)

```java
/**
 * Representasi Field schema untuk parsing JSON.
 *
 * @brief Model internal untuk metadata field.
 * @group Data Models
 * @since 1.0.0
 * @author Tim Backend
 * @immutable
 *
 * @property name Nama field (WAJIB).
 * @property type Tipe data (default: "string").
 * @property visibility Level visibility (default: PRIVATE).
 * @see extractField
 */
public record Field(
    String name,
    String type,        // default ""
    String visibility   // default "private"
) {
    /** @brief Constructor alternatif dengan default. */
    public Field(String name) {
        this(name, "string", "private");
    }
}
```

---

### F. C# (Class + Record)

```csharp
/// Representasi Field schema untuk parsing JSON.
/// 
/// @brief Model internal untuk metadata field.
/// @group Data Models
/// @since 1.0.0
/// @author Tim Backend
/// @immutable
/// 
/// <param name="Name">Nama unik field (WAJIB).</param>
/// <param name="Type">Tipe data (default: "").</param>
/// <param name="Visibility">Level visibility (default: Private).</param>
public record Field(
    string Name,
    string Type = "",
    string Visibility = "private"
) {
    /// Constructor alternatif dengan default.
    /// </summary>
    public Field(string Name) : this(Name, "", "private") {}
}
```

---

### G. PHP (Class + Typed Properties)

```php
/**
 * Representasi Field schema untuk parsing JSON.
 * 
 * @brief Model internal untuk metadata field.
 * @group Data Models
 * @since 1.0.0
 * @author Tim Backend
 * @immutable
 * 
 * @property string $name Nama unik field (WAJIB).
 * @property string $type Tipe data (default: "").
 * @property string $visibility Level visibility (default: "private").
 * @see extract_field()
 */
class Field {
    /** @var string Nama field (WAJIB). */
    public string $name;
    /** @var string Tipe data (default: ""). */
    public string $type = "";
    /** @var string Level visibility (default: "private"). */
    public string $visibility = "private";
    
    /**
     * @param string $name
     * @param string $type (opsional)
     * @param string $visibility (opsional)
     */
    public function __construct(string $name, string $type = "", string $visibility = "private") {
        // ...
    }
}
```

---

### H. Ruby (Class dengan Attributes)

```ruby
# Representasi Field schema untuk parsing JSON.
#
# @brief Model internal untuk metadata field.
# @group Data Models
# @since 1.0.0
# @author Tim Backend
# @immutable
#
# @attr_reader [String] name Nama unik field (WAJIB).
# @attr_reader [String] type Tipe data (default: nil).
# @attr_reader [String] visibility Level visibility (default: "private").
# @see #extract_field
class Field
  attr_reader :name, :type, :visibility
  
  # @param name [String] - Wajib.
  # @param type [String] - Opsional.
  # @param visibility [String] - Opsional.
  def initialize(name, type = nil, visibility = "private")
    # ...
  end
end
```
---

### I. Zig (Struct + Container Doc)

```zig
/// Representasi Field schema untuk parsing JSON.
pub const Field = struct {
    /// Nama unik field (WAJIB).
    name: []const u8,
    /// Tipe data (default: "").
    type: []const u8 = "",
    /// Level visibility (default: "private").
    visibility: []const u8 = "private",

    /// @brief Buat Field baru dari name.
    /// @param name Nama unik field.
    /// @return Field Instance Field.
    pub fn init(name: []const u8) Field {
        return .{ .name = name };
    }
};
```

---

## 5. Doc Enum / Constants

### A. TypeScript

```typescript
/**
 * @brief Level visibility untuk Field schema.
 * @enum {string}
 * @group Data Models
 * @since 1.0.0
 */
enum Visibility {
  Private = "private",
  Protected = "protected",
  Public = "public"
}
```

---

### B. Python (Enum)

```python
from enum import Enum

class Visibility(str, Enum):
    """Level visibility untuk Field schema.
    
    @brief Level visibility.
    @group Data Models
    @since 1.0.0
    
    Values:
        PRIVATE: Field hanya bisa diakses di dalam class.
        PROTECTED: Field bisa diakses di subclass.
        PUBLIC: Field bisa diakses dari mana saja.
    """
    PRIVATE = "private"
    PROTECTED = "protected"
    PUBLIC = "public"
```

---

### C. Rust (Enum)

```rust
/// Level visibility untuk Field schema.
///
/// @brief Level visibility.
/// @group Data Models
/// @since 1.0.0
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Visibility {
    /// Field hanya diakses di dalam module.
    Private,
    /// Field bisa diakses oleh subclass/module turunan.
    Protected,
    /// Field bisa diakses publik.
    Public,
}
```

---

### D. Go (Const Block + iota)

```go
// Level visibility untuk Field schema.
//
// @brief Level visibility.
// @group Data Models
// @since 1.0.0
type Visibility int

const (
    // VisibilityPrivate field hanya diakses di dalam package.
    //
    // @value private
    VisibilityPrivate Visibility = iota
    // VisibilityProtected field bisa diakses subclass.
    //
    // @value protected
    VisibilityProtected
    // VisibilityPublic field bisa diakses publik.
    //
    // @value public
    VisibilityPublic
)
```

---

### E. Java / Kotlin

```java
/**
 * Level visibility untuk Field schema.
 *
 * @brief Level visibility.
 * @group Data Models
 * @since 1.0.0
 * @see Visibility
 */
public enum Visibility {
    /** Field hanya diakses di dalam class. */
    PRIVATE,
    /** Field bisa diakses subclass. */
    PROTECTED,
    /** Field bisa diakses publik. */
    PUBLIC
}
```

```kotlin
/**
 * Level visibility untuk Field schema.
 *
 * @brief Level visibility.
 * @group Data Models
 * @since 1.0.0
 * @see Visibility
 */
enum class Visibility {
    /** Field hanya diakses di dalam class. */
    PRIVATE,
    /** Field bisa diakses subclass. */
    PROTECTED,
    /** Field bisa diakses publik. */
    PUBLIC
}
```

---

### F. PHP (Enum)

```php
/**
 * Level visibility untuk Field schema.
 * 
 * @brief Level visibility.
 * @group Data Models
 * @since 1.0.0
 */
enum Visibility: string {
    /** Field hanya diakses di dalam class. */
    case PRIVATE = 'private';
    /** Field bisa diakses subclass. */
    case PROTECTED = 'protected';
    /** Field bisa diakses publik. */
    case PUBLIC = 'public';
}
```

---

### G. C# (Enum)

```csharp
/// Level visibility untuk Field schema.
/// 
/// @brief Level visibility.
/// @group Data Models
/// @since 1.0.0
public enum Visibility {
    /// Field hanya diakses di dalam class.
    Private,
    /// Field bisa diakses subclass.
    Protected,
    /// Field bisa diakses publik.
    Public
}
```
---

### H. Zig (Enum)

```zig
/// Level visibility untuk Field schema.
pub const Visibility = enum {
    /// Field hanya diakses di dalam struct.
    private,
    /// Field bisa diakses publik.
    public,
};
```

---

## 6. Async / Promise Documentation

### A. JavaScript / TypeScript

```typescript
/**
 * @brief Fetch data dari remote API.
 * @param {string} endpoint - URL endpoint API.
 * @param {RequestInit} [options] - Opsi fetch tambahan (headers, method, dll).
 * @return {Promise<ApiResponse<T>>} Promise yang resolve ke response.
 * @throw {AbortError} Kalau request di-abort.
 * @throw {TypeError} Kalau endpoint bukan string valid URL.
 * @example
 * const data = await fetchData<Field[]>('/api/fields');
 * console.log(data.items);
 * @since 1.3.0
 * @async
 * @public
 */
async function fetchData<T>(
  endpoint: string,
  options?: RequestInit
): Promise<ApiResponse<T>> {
  // ...
}
```

---

### B. Python (async/await)

```python
async def fetch_data(endpoint: str, options: RequestInit | None = None) -> ApiResponse[T]:
    """Fetch data dari remote API.
    
    @brief Fetch data dari remote API.
    @param endpoint (str): URL endpoint API.
    @param options (RequestInit, optional): Opsi request tambahan.
    @return ApiResponse[T]: Response API.
    @raise AbortError: Request di-abort.
    @raise TypeError: Endpoint bukan string valid URL.
    
    @example
        data = await fetch_data('/api/fields')
        print(data.items)
    
    @since v1.3.0
    @async
    @public
    """
    # ...
```

---

### C. Rust (async fn)

```rust
/// Fetch data dari remote API.
///
/// # Arguments
///
/// * `endpoint` - URL endpoint API.
/// * `options` - Opsi request tambahan (opsional).
///
/// # Returns
///
/// `Result<ApiResponse<T>, ApiError>` - Response API atau error.
///
/// # Errors
///
/// * `AbortError` - Request di-abort.
/// * `TypeError` - Endpoint bukan string valid URL.
///
/// # Examples
///
/// ```no_run
/// let data = fetch_data::<Field>("/api/fields").await?;
/// println!("{:?}", data.items);
/// ```
///
/// # Since
///
/// 1.3.0
///
/// # Async
///
/// Fungsi ini async dan butuh runtime async.
#[must_use]
pub async fn fetch_data<T>(
    endpoint: impl Into<String>,
    options: Option<RequestInit>,
) -> Result<ApiResponse<T>, ApiError> {
    // ...
}
```

---

### D. Go (goroutine + channels / context)

```go
// FetchData fetch data dari remote API.
//
// @param endpoint string - URL endpoint API.
// @param options *RequestInit - Opsi request tambahan (opsional).
// @return (*ApiResponse[T], error) Response API atau error.
// @return error AbortError, TypeError, dll.
// @example
//
//	data, err := FetchData[Field]("/api/fields", nil)
//	if err != nil {
//	    return nil, err
//	}
//	fmt.Println(data.Items)
//
// @since v1.3.0
// @async Gunakan goroutine untuk concurrency.
// @public
func FetchData[T any](endpoint string, options *RequestInit) (*ApiResponse[T], error) {
    ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
    defer cancel()
    // ...
}
```

---

### E. Java (CompletableFuture / reactive)

```java
/**
 * Fetch data dari remote API.
 *
 * @param endpoint URL endpoint API.
 * @param <T> Tipe response.
 * @return {@link CompletableFuture}<{@link ApiResponse}<{@link T}>> Response async.
 * @throws AbortException Request di-abort.
 * @throws IllegalArgumentException Endpoint invalid.
 * @since 1.3.0
 * @async
 * @public
 * @see #fetchDataBlocking(String)
 */
public <T> CompletableFuture<ApiResponse<T>> fetchData(String endpoint) {
    // ...
}
```

---

## 7. Generic Type Parameter Documentation

### A. TypeScript

```typescript
/**
 * @brief Convert array of items ke typed model.
 * @template T - Tipe item yang diharapkan (extends BaseModel).
 * @template U - Format output (JSON | XML).
 * @param {Array<unknown>} items - Raw items.
 * @param {U} format - Format output.
 * @return {Array<T>} Array yang sudah di-cast ke T.
 * @since 1.4.0
 */
function convertItems<T extends BaseModel, U extends "json" | "xml">(
  items: unknown[],
  format: U
): T[] {
  // ...
}
```

---

### B. Rust

```rust
/// Convert Vec of items ke typed model.
///
/// # Type Parameters
///
/// * `T` - Tipe item (harus `DeserializeOwned`).
/// * `U` - Format output (`json` atau `xml`).
///
/// # Arguments
///
/// * `items` - Raw items.
/// * `format` - Format output.
///
/// # Returns
///
/// Vec<T> yang sudah di-deserialize.
///
/// # Since
///
/// 1.4.0
fn convert_items<T, U>(items: &[Value], format: U) -> Vec<T>
where
    T: DeserializeOwned,
    U: AsRef<str>,
{
    // ...
}
```

---

### C. Python (Generic)

```python
from typing import TypeVar, Generic, List

T = TypeVar("T", bound=BaseModel)
U = TypeVar("U", str, Literal["json", "xml"])

def convert_items(items: List[dict], fmt: U) -> List[T]:
    """Convert array items ke typed model.
    
    @brief Convert items ke typed model.
    @template T Tipe item (extends BaseModel).
    @template U Format output (json | xml).
    @param items (List[dict]): Raw items.
    @param fmt (U): Format output.
    @return List[T]: Items yang sudah di-cast.
    @since 1.4.0
    """
    # ...
```

---

## 8. Deprecation dengan Migration Guide

### A. TypeScript

```typescript
/**
 * @brief Parse visibility dari string.
 * @param {string} input - Input string.
 * @return {Visibility} Enum visibility.
 * @throws {ValueError} Kalau input ga valid.
 * @since 1.0.0
 * @deprecated Sejak 2.0.0, pakai `parseVisibilityV2()` yang support map visibility baru.
 * @see parseVisibilityV2
 * @migration Gunakan `parseVisibilityV2` dengan signature yang sama.
 */
function parseVisibility(input: string): Visibility {
  // ...
}
```

---

### B. Rust

```rust
/// Parse visibility dari string.
///
/// @deprecated Sejak 2.0.0, pakai [`parse_visibility_v2`] yang support `SnapshotVisibility`.
/// @migration Ganti panggilan ke `parse_visibility_v2(value).await?`.
/// @since 1.0.0
pub fn parse_visibility(input: &str) -> Result<Visibility, ValueError> {
    // ...
}
```

---

## 9. Overload / Polymorphic Functions

### A. TypeScript

```typescript
/**
 * @brief Create user dengan flexible signature.
 * @overload
 * @param {string} email
 * @param {string} password
 * @return {User}
 *
 * @overload
 * @param {Object} opts
 * @param {string} opts.email
 * @param {string} [opts.password]
 * @param {string} [opts.name]
 * @return {User}
 */
function createUser(...args: any[]): User {
  // ...
}
```

---

### B. Java

```java
/**
 * Create user dengan flexible signature.
 *
 * @overload
 * @param email Email user.
 * @param password Password user.
 * @return User baru.
 *
 * @overload
 * @param opts Opsi user lengkap.
 * @return User baru.
 */
public User createUser(String email, String password) {
    return createUser(Map.of("email", email, "password", password));
}
public User createUser(CreateUserOpts opts) {
    // ...
}
```

---

## 10. Event / Callback Documentation

### A. TypeScript

```typescript
/**
 * @brief Event handler untuk onUserUpdate.
 * @callback onUserUpdate
 * @param {User} user - User yang diupdate.
 * @param {UpdateReason} reason - Alasan update.
 * @return {void}
 * @event
 * @see UserManager
 */
type onUserUpdate = (user: User, reason: UpdateReason) => void;

/**
 * @brief Subscribe notifikasi user update.
 * @param {onUserUpdate} callback - Handler callback.
 * @return {Unsubscribe} Fungsi untuk unsubscribe.
 * @throw {TypeError} Kalau callback bukan fungsi.
 * @example
 * const unsub = onUserUpdate((user, reason) => {
 *   console.log(`User ${user.id} updated: ${reason}`);
 * });
 * // later: unsub();
 * @since 1.5.0
 */
function onUserUpdate(callback: onUserUpdate): Unsubscribe {
    // ...
}
```

---

### B. Python

```python
def on_user_update(callback: Callable[[User, UpdateReason], None]) -> Callable[[], None]:
    """Subscribe notifikasi user update.
    
    @brief Subscribe notifikasi user update.
    @callback onUserUpdate
    @param callback (Callable[[User, UpdateReason], None]): Handler callback.
    @return Callable[[], None]: Fungsi unsubscribe.
    @raise TypeError: Kalau callback bukan callable.
    
    @example
        def handler(user, reason):
            print(f"User {user.id} updated: {reason}")
        unsub = on_user_update(handler)
        # later: unsub()
    
    @since v1.5.0
    @event
    """
    # ...
```

---

## 11. Configuration / Schema Documentation

### A. TypeScript (Zod Schema)

```typescript
/**
 * @brief Schema konfigurasi aplikasi.
 * @schema
 * @group Configuration
 * @since 1.0.0
 */
const AppConfigSchema = z.object({
  /** Port server (default: 3000). */
  port: z.number().int().positive().default(3000),
  /** URL database. */
  databaseUrl: z.string().url(),
  /** Mode logging (debug | info | warn | error). */
  logLevel: z.enum(["debug", "info", "warn", "error"]).default("info"),
  /** Enable rate limiter. */
  enableRateLimiter: z.boolean().default(true),
  /** Max request per minute per IP. */
  rateLimitMax: z.number().int().positive().default(100),
  /** Environment (development | staging | production). */
  env: z.enum(["development", "staging", "production"]).default("development"),
  /** Secret key untuk JWT. */
  jwtSecret: z.string().min(32),
  /** TTL cache dalam detik. */
  cacheTtl: z.number().int().positive().default(3600),
});
```

---

### B. Python (Pydantic)

```python
from pydantic import BaseModel, Field
from typing import Literal

class AppConfig(BaseModel):
    """Schema konfigurasi aplikasi.
    
    @brief Schema konfigurasi aplikasi.
    @schema
    @group Configuration
    @since 1.0.0
    
    Attributes:
        port (int): Port server (default: 3000).
        database_url (str): URL database.
        log_level (str): Mode logging (default: "info").
        enable_rate_limiter (bool): Enable rate limiter (default: True).
    """
    port: int = Field(default=3000, gt=0)
    database_url: str
    log_level: Literal["debug", "info", "warn", "error"] = "info"
    enable_rate_limiter: bool = True
    rate_limit_max: int = Field(default=100, gt=0)
    env: Literal["development", "staging", "production"] = "development"
    jwt_secret: str = Field(min_length=32)
    cache_ttl: int = Field(default=3600, gt=0)
```

---

### C. Rust (serde + validation)

```rust
/// Schema konfigurasi aplikasi.
///
/// @brief Konfigurasi global aplikasi.
/// @schema
/// @group Configuration
/// @since 1.0.0
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct AppConfig {
    /// Port server (default: 3000).
    #[serde(default = "default_port")]
    pub port: u16,
    /// URL database.
    pub database_url: String,
    /// Mode logging.
    pub log_level: LogLevel,
    /// Enable rate limiter (default: true).
    pub enable_rate_limiter: bool,
    /// Max request per minute per IP.
    pub rate_limit_max: u32,
    /// Environment.
    pub env: Environment,
    /// Secret key untuk JWT (min 32 chars).
    pub jwt_secret: String,
    /// TTL cache dalam detik.
    pub cache_ttl: u32,
}
```

---

## 12. Error Code Documentation

### A. TypeScript

```typescript
/**
 * @brief Enum error code untuk API.
 * @enum {number}
 * @group Errors
 * @since 1.0.0
 * @see ApiException
 */
export enum ErrorCode {
  /** 400 - Request invalid. */
  BadRequest = 400,
  /** 401 - Belum login / token expired. */
  Unauthorized = 401,
  /** 403 - Tidak punya akses. */
  Forbidden = 403,
  /** 404 - Resource tidak ketemu. */
  NotFound = 404,
  /** 422 - Validation gagal. */
  UnprocessableEntity = 422,
  /** 429 - Too many requests. */
  TooManyRequests = 429,
  /** 500 - Server error internal. */
  InternalServerError = 500,
}
```

---

### B. Python

```python
class ErrorCode(IntEnum):
    """Enum error code untuk API.
    
    @brief Kode error standar API.
    @group Errors
    @since 1.0.0
    """
    BAD_REQUEST = 400
    UNAUTHORIZED = 401
    FORBIDDEN = 403
    NOT_FOUND = 404
    UNPROCESSABLE_ENTITY = 422
    TOO_MANY_REQUESTS = 429
    INTERNAL_SERVER_ERROR = 500
```

---

## 13. Deprecation Tag (Template Formal)

```
/**
 * @deprecated Sejak 2.0.0 — pakai [fungsi_baru]() untuk mengganti.
 * @reason [Alasan: dioptimasi, dipecah, atau ada bug].
 * @migration
 *   Langkah migrasi:
 *   1. Ganti panggilan `fungsiLama()` ke `fungsiBaru()`.
 *   2. Update parameter: `paramLama` -> `paramBaru`.
 *   3. Test ulang unit test yang terkait.
 *   Contoh:
 *   ```ts
 *   // LAMA
 *   const x = parseUserData(raw);
 *   // BARU
 *   const x = parseUserDataV2(raw, { strict: true });
 *   ```
 * @replacement fungsiBaru()
 * @since 1.0.0
 */
```

---

## 14. Security / Privacy Annotations

### Tag Keamanan & Privacy

```typescript
/**
 * @brief Hash password dengan bcrypt.
 * @param {string} password - Password plaintext.
 * @return {Promise<string>} Hashed password.
 * @throw {ValueError} Kalau password < 8 chars.
 * @security
 *   - Password TIDAK PERNAH di-log atau di-cache.
 *   - Rate limiter wajib aktif untuk endpoint ini.
 *   - Hash cost default: 12 (bisa diubah lewat env).
 * @privacy
 *   - Data sensitif: password hash, salt.
 *   - Compliance: OWASP ASVS V2.2.
 * @since 1.0.0
 * @threadsafe Ya (stateless hashing).
 */
```

---

### Rust

```rust
/// Hash password dengan bcrypt.
///
/// @security
///   - Password TIDAK PERNAH di-log atau di-cache.
///   - Rate limiter wajib aktif.
///   - Hash cost: 12 (env: BCRYPT_COST).
/// @privacy
///   - Data sensitif: password hash, salt.
///   - Compliance: OWASP ASVS V2.2.
/// @since 1.0.0
/// @threadsafe Ya (stateless hashing).
/// @complexity O(cost) — default cost 12.
pub fn hash_password(password: &str) -> Result<String, ValueError> {
    // ...
}
```

---

## 15. Performance Annotations

```typescript
/**
 * @brief Parse JSON besar dengan streaming.
 * @param {ReadableStream} stream - Stream JSON.
 * @return {AsyncIterator<T>} Iterator typed items.
 * @performance
 *   - Memory: O(1) per item (streaming).
 *   - Time: O(n) dimana n = total items.
 *   - Benchmark: ~5ms/item untuk payload 10MB.
 * @complexity O(n) time, O(1) memory.
 * @since 1.3.0
 * @streaming
 */
async function* streamParseItems<T>(stream: ReadableStream): AsyncIterator<T> {
    // ...
}
```

---

## 16. Module / Package Level Documentation

### A. TypeScript

```typescript
/**
 * @module DataLayer
 * @brief Layer akses data untuk database operations.
 * @description
 *   Modul ini menangani semua operasi database:
 *   - Query builder
 *   - Transaction management
 *   - Migration helpers
 * @group Data Layer
 * @since 1.0.0
 * @author Tim Backend
 * @license MIT
 * @exports FieldManager, parseVisibility, ErrorCode
 */
export { FieldManager, parseVisibility, ErrorCode };
```

---

### B. Python (Package `__init__.py`)

```python
"""DataLayer - Layer akses data untuk database operations.
    
@brief Layer akses data.
@description
    Modul ini menangani semua operasi database:
    - Query builder
    - Transaction management
    - Migration helpers
@group Data Layer
@since v1.0.0
@author Tim Backend
@license MIT
"""
from .field import FieldManager
from .visibility import parse_visibility
from .errors import ErrorCode

__all__ = ["FieldManager", "parse_visibility", "ErrorCode"]
```

---

### C. Rust (Crate root `lib.rs`)

```rust
//! # DataLayer
//!
//! Layer akses data untuk database operations.
//!
//! @brief Layer akses data.
//! @description
//!   Modul ini menangani semua operasi database:
//!   - Query builder
//!   - Transaction management
//!   - Migration helpers
//! @group Data Layer
//! @since 1.0.0
//! @author Tim Backend
//! @license MIT

pub mod field;
pub mod visibility;
pub mod errors;
```
---

### D. Zig (Root file `main.zig` / `lib.zig`)

```zig
//! # DataLayer
//!
//! Layer akses data untuk database operations.
//!
//! @brief Modul akses data.
//! @description
//!   Modul ini menangani semua operasi database:
//!   - Query builder
//!   - Transaction management
//!   - Migration helpers
//! @group Data Layer
//! @since 1.0.0
//! @author Tim Backend
//! @license MIT

pub const field = @import("field.zig");
pub const visibility = @import("visibility.zig");
pub const errors = @import("errors.zig");
```

---

## 17. Test / Fixture Documentation

### A. TypeScript (Vitest / Jest)

```typescript
/**
 * @brief Test parseVisibility dengan input valid.
 * @param visibility - Input visibility.
 * @param expected - Expected result.
 * @testOf parseVisibility
 * @runas Unit Test
 * @since 1.0.0
 * @fixture
 * @group Tests
 */
describe("parseVisibility", () => {
  test.each([
    ["private", Visibility.Private],
    ["public", Visibility.Public],
  ])("parseVisibility(%s) returns %s", (input, expected) => {
    expect(parseVisibility(input)).toBe(expected);
  });
});
```

---

### B. Python (pytest)

```python
import pytest

class TestParseVisibility:
    """Test parseVisibility dengan berbagai input.
    
    @brief Test suite untuk parseVisibility.
    @testOf "parse_visibility"
    @runas Unit Test
    @since v1.0.0
    @fixture
    @group Tests
    """
    @pytest.mark.parametrize("input,expected", [
        ("private", Visibility.PRIVATE),
        ("public", Visibility.PUBLIC),
    ])
    def test_parse_visibility(self, input: str, expected: Visibility) -> None:
        """Test parseVisibility dengan input valid.
        
        @param input (str): Input visibility.
        @param expected (Visibility): Expected result.
        """
        assert parse_visibility(input) == expected
```

---

## 18. ADR (Architecture Decision Record)

```markdown
<!-- File: docs/adr/adr-001-use-doxygen-universal.md -->

# ADR-001: Gunakan "Doxygen Universal" sebagai standar doc lintas bahasa

@adr 001
@status accepted
@since 2024-01-15
@author Tim Backend
@reviewer Tim Architect
@group Documentation

@brief Tetapkan standar dokumentasi seragam lintas bahasa.

@context
  Project menggunakan multi bahasa (TS, Python, Rust).
  Format doc beda-beda setiap bahasa menyebabkan inkonsistensi.

@decision
  Gunakan Doxygen tags sebagai standar, delimiter tetap bawaan bahasa.

@consequences
  - Semua tooling tetap kompatibel (JSDoc, rustdoc, Sphinx).
  - Konsistensi tag lintas project.
  - Perlu update linter config.

@alternatives
  1. Google Style Guide — terlalu verbose.
  2. NumPy Style (Python only) — ga cocok lintas bahasa.
```

→ Didokumentasikan dalam ADR file, tapi bisa direferensi dari doc:

```typescript
/**
 * @brief Parse visibility.
 * @see docs/adr/adr-001-use-doxygen-universal.md
 * @context Dipilih karena konsistensi lintas bahasa (Doxygen Universal).
 */
```

---

## 19. Tag Doxygen + Emoji

| Tag | Emoji | Makna |
|---|---|---|
| `@brief` | 🎯 | Tujuan utama / aksi |
| `@param` | 📥 | Input yang masuk |
| `@return` / `@returns` | 📤 | Output yang keluar |
| `@throws` / `@exception` | ⚠️ / 🚨 | Error yang bisa terjadi |
| `@example` | 💡 | Contoh penggunaan |
| `@see` | 🔗 | Lihat juga / related |
| `@todo` | 📌 | Pekerjaan rumah |
| `@deprecated` | 🗑️ | Udah usang, jangan dipake |
| `@since` | 📅 | Sejak versi berapa |
| `@note` | 🧠 | Catatan penting |
| `@warning` | ⚡ | Peringatan penting |
| `@group` | 📁 | Group / module |
| `@memberof` | 🔖 | Anggota dari group lain |
| `@author` | ✍️ | Penulis |
| `@version` | 🔢 | Versi |
| `@return` | 📤 | Return value |
| `@module` | 📦 | Module definition |
| `@class` | 🏗️ | Class definition |
| `@interface` | 📐 | Interface definition |
| `@struct` | 🧱 | Struct definition |
| `@enum` | 📋 | Enum definition |
| `@template` | 🔀 | Generic type parameter |
| `@overload` | 🔄 | Polymorphic signature |
| `@callback` | 🤙 | Callback signature |
| `@event` | 📢 | Event emitter |
| `@schema` | 📊 | Configuration schema |
| `@async` | ⏳ | Async function |
| `@threadsafe` | 🔒 | Thread-safe |
| `@reentrant` | 🔁 | Reentrant |
| `@security` | 🛡️ | Security notes |
| `@privacy` | 🔐 | Privacy compliance |
| `@complexity` | 📈 | Time/space complexity |
| `@migration` | 🚚 | Migration guide |
| `@replacement` | 🔁 | Replacement function |
| `@immutable` | 🧊 | Immutable type |
| `@abstract` | 🖥️ | Abstract class/method |
| `@public` | 🌍 | Public API |
| `@private` | 🔒 (internal) | Private/internal |
| `@fixture` | 🧪 | Test fixture |
| `@testOf` | 🧪 | Function under test |
| `@adr` | 📋 | ADR reference |
| `@status` | ✅ | Status (proposed/accepted/rejected) |

---

## 20. Aturan Pendek (2 Baris untuk Helper Kecil)

```ts
// Helper kecil
/** @brief Cek apakah user aktif. @return {boolean} */
function isUserActive(user: User): boolean {
  return user.status === "active";
}
```

```py
# Helper kecil
def is_active(user: User) -> bool:
    """@brief Cek apakah user aktif. @return {boolean}."""
    return user.status == "active"
```

```rust
// Helper kecil
/// @brief Cek apakah user aktif.
/// @return `true` kalau aktif.
pub fn is_active(user: &User) -> bool {
    user.status == "active"
}
```

---

## 21. Aturan Panjang (Public API / > 20 baris)

Fungsi > 20 baris atau public API: Wajib pake template lengkap + @example + @throw + @see + @since.

---

## 22. Commit Rule

- **Commits**: Wajib ada docs update kalau nambah @param atau @return.
- **Pre-commit hook (opsional)**:
  - JS/TS: `eslint-plugin-jsdoc` + `eslint-plugin-jsdoc/no-missing-param-documentation`
  - Python: `pydocstyle` atau `docformatter`
  - Rust: `cargo doc --no-deps` + `rustdoc`
  - Go: `golint` / `staticcheck`
  - Java: `javadoc` + Checkstyle
  - PHP: `phpcs` dengan standard `phpdoc`

---

## 23. Dokumentasi Nested / Optional Parameter

```typescript
/**
 * @brief Buat user baru.
 * @param {Object} userData - Data user.
 * @param {string} userData.email - Email (WAJIB).
 * @param {string} userData.password - Password (WAJIB, min 8 char).
 * @param {string} [userData.name] - Nama (opsional).
 * @param {string} [userData.avatar] - URL avatar (opsional).
 * @param {boolean} [userData.verified=false] - Status verified (opsional, default false).
 * @return {User} User baru yang dibuat.
 * @throw {ValidationError} Kalau email invalid.
 * @throw {WeakPasswordError} Kalau password < 8 char.
 * @example
 * const user = await createUser({
 *   email: 'ahmad@mail.com',
 *   password: 'rahasia123',
 *   name: 'Ahmad'
 * });
 */
```

---

## 24. Documentation Testing (Doctest)

### A. Rust (Built-in doctest)

```rust
/// ```
/// let result = add(2, 3);
/// assert_eq!(result, 5);
/// ```
///
/// ```
/// // Error case
/// let result = div(10, 0);
/// assert!(result.is_err());
/// ```
pub fn add(a: i32, b: i32) -> i32 { a + b }
```

---

### B. Swift

```swift
/// ```
/// let result = try add(2, 3)
/// XCTAssertEqual(result, 5)
/// ```
public func add(_ a: Int, _ b: Int) throws -> Int {
    a + b
}
```

---

### C. Kotlin (KDoc + Dokka)

```kotlin
/**
 * ```
 * assertEquals(add(2, 3), 5)
 * ```
 */
fun add(a: Int, b: Int): Int = a + b
```

---

## 25. Reference Antar Modul

```typescript
/**
 * @see parseVisibility
 * @see Visibility
 * @see extractField
 * @see ADR-001 (docs/adr/adr-001-use-doxygen-universal.md)
 * @see Issue #234 — Migrasi ke V2
 */
```

```python
"""
@see parse_visibility
@see Visibility
@see extract_field
@see docs/adr/adr-001-use-doxygen-universal.md
@see Issue #234
"""
```

---

## 26. Dokumentasi Return Type (Complex)

```typescript
/**
 * @brief Parse API response.
 * @return {ApiResponse<T>} Object response.
 * @property {number} status - HTTP status code.
 * @property {Object} headers - Response headers.
 * @property {T} data - Data payload.
 * @property {string?} error - Pesan error (kalau status >= 400).
 *
 * @example
 * const res = await fetchData<User[]>('/users');
 * if (res.error) throw new Error(res.error);
 * return res.data;
 */
```

---

## 27. Monorepo / Multi-Language Project

```
monorepo/
├── packages/
│   ├── api/
│   │   ├── src/
│   │   │   └── index.ts          # Doxygen: @module
│   │   └── STYLE_GUIDE.md
│   ├── models/
│   │   └── src/
│   │       └── field.py          # Doxygen: @brief
│   ├── core/
│   │   └── src/
│   │       └── lib.rs            # Rustdoc + Doxygen tags
│   ├── shared/
│   │   └── types/
│   │       ├── Field.java        # Javadoc + Doxygen
│   │       ├── Field.cs          # XML Doc + Doxygen
│   │       └── Field.php         # phpDocumentor + Doxygen
│   └── docs/
│       └── docs.adr.adr-001-standar-doxygen-universal.md
└── AGENTS.Style.md               # STANDAR GLOBAL
```

**Aturan monorepo:**
1. File `STYLE_GUIDE.md` per-package WAJIB mengacu ke `AGENTS.Style.md` root.
2. Tag @group wajib match package name.
3. @since harus konsisten dengan `CHANGELOG.md` root.
4. Cross-reference antar bahasa pakai path relatif dari file saat itu.

---

## 28. CI/CD Integration

```yaml
# .github/workflows/docs-check.yml
name: Documentation Lint
on: [push, pull_request]

jobs:
  docs-lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
      - name: Install dependencies
        run: npm install -g eslint eslint-plugin-jsdoc
      - name: Lint JS/TS docs
        run: npx eslint --plugin jsdoc --rule '{"jsdoc/require-param-description": "error"}' '**/*.{ts,js}'
      - uses: actions/setup-python@v5
        with:
          python-version: '3.12'
      - name: Lint Python docs
        run: pip install pydocstyle && pydocstyle src/
      - uses: dtolnay/rust-toolchain@stable
      - name: Lint Rust docs
        run: cargo doc --no-deps --document-private-items
      - uses: actions/setup-go@v5
        with:
          go-version: '1.22'
      - name: Lint Go docs
        run: go install github.com/mkchoi212/fac@latest && fac ./...
```

**Pre-commit hook config** (`.pre-commit-config.yaml`):

```yaml
repos:
  - repo: https://github.com/pre-commit/mirrors-eslint
    rev: v9.0.0
    hooks:
      - id: eslint
        args: ['--plugin', 'jsdoc', '--rule', '{"jsdoc/require-param-description": "error"}']
        files: '\.(ts|js)$'
  - repo: https://github.com/pre-commit/mirrors-pydocstyle
    rev: v6.3.0
    hooks:
      - id: pydocstyle
        files: '\.py$'
  - repo: local
    hooks:
      - id: cargo-doc
        name: Lint Rust documentation
        entry: bash -c 'cd rust && cargo doc --no-deps --document-private-items'
        language: system
        types: [rust]
      - id: gofmt
        name: Check Go doc comments
        entry: bash -c 'cd go && go install github.com/mkchoi212/fac@latest && fac ./...'
        language: system
        types: [go]
```

---

## 29. README / Badge Integration

```markdown
# Project Name

![Documentation](https://img.shields.io/badge/docs-Doxygen%20Universal-blue)
![Rust](https://img.shields.io/badge/rust-docs-green)
![TypeScript](https://img.shields.io/badge/TypeScript-typedocs-blue)
![Python](https://img.shields.io/badge/Python-autodoc-yellow)

**Dokumentasi seragam lintas bahasa.** Menggunakan standar "Doxygen Universal":
- Delimiter tetap bawaan setiap bahasa.
- Tag & struktur seragam (Doxygen standard).
- Tooling: cargo doc, TypeDoc, Sphinx.

## Section

[See ADR-001](../docs/adr/adr-001-use-doxygen-universal.md)
[API Reference](docs/api-reference.md)
```

---

## 30. Migration Guide Template (Major Version)

```markdown
# Migration Guide v3.0.0

## Overview
Version 3.0.0 menghapus API lama dan mengganti dengan versi baru yang lebih type-safe.

## Breaking Changes

### 1. `parseVisibility` → `parseVisibilityV2`

#### ❌ Old (v2.x)

@deprecated Sejak 2.0.0 (akan dihapus di v3.0.0)

```typescript
// Old signature
function parseVisibility(input: string): Visibility
```

#### ✅ New (v3.0.0)

```typescript
// New signature — support map visibility
function parseVisibilityV2(input: string, opts?: { strict: boolean }): Visibility
```

#### ⚡ Migration Steps

1. Ganti semua `parseVisibility()` → `parseVisibilityV2(input, { strict: true })`.
2. Remove fallback handling (sudah strict by default).
3. Update unit test expectations.

#### 📅 Timeline

- v2.0.0: `@deprecated` ditambahkan.
- v3.0.0: API lama dihapus.
- v4.0.0: cleanup doc reference.

#### 🔗 References
- Issue: #445
- PR: #446
- ADR: docs/adr/adr-002-remove-visibility-deep-docs.md
```

---

## 31. Quick Reference Table

| Use Case | Tag Wajib | Tag Opsional |
|---|---|---|
| Function simple | `@brief`, `@return` | `@throw` |
| Function complex (>20 baris) | `@brief`, `@param`, `@return` | `@throw`, `@example`, `@see`, `@since` |
| Class / Struct / Interface | `@brief`, `@description` | `@property`, `@group`, `@since`, `@author` |
| Enum | `@brief`, `@enum` | `@value`, `@group`, `@since` |
| Generic Function | `@brief`, `@template`, `@param`, `@return` | `@example`, `@complexity` |
| Async / Promise | `@brief`, `@param`, `@return`, `@async` | `@throw`, `@performance` |
| Callback / Event | `@brief`, `@callback`, `@param` | `@event`, `@see` |
| Config Schema | `@brief`, `@schema`, `@group` | `@property` |
| Error Code | `@brief`, `@enum` | `@value`, `@since` |
| Module / Package | `@brief`, `@module` | `@description`, `@group`, `@exports`, `@license` |
| Deprecated | `@deprecated`, `@since`, `@migration` | `@replacement`, `@reason` |
| Security Sensitive | `@brief`, `@param`, `@return` | `@security`, `@privacy`, `@threadsafe` |

---

## 32. Checklist Cepat Sebelum Commit

```markdown
- [ ] @brief ada (1 kalimat).
- [ ] Semua @param tercatat dan describe.
- [ ] @return ada (jika bukan void).
- [ ] @throw ada (jika ada error handling).
- [ ] @since sesuai versi CHANGELOG.
- [ ] @group sesuai module name.
- [ ] @example untuk public API.
- [ ] @deprecated + @migration untuk API usang.
- [ ] @security/@privacy untuk fungsi sensitif.
- [ ] Delimiter sesuai bahasa.
- [ ] IDE snippet tersedia.
```

---

Semoga acuan ini cukup detail dan siap dipakai di semua project!
