import Foundation

/// 按 glslang 的报错补上显式类型转换。
///
/// WE 的着色器按 HLSL 的规则写：vec4 可以直接赋给 vec2（截断），float 可以直接赋给 int，
/// 传给函数的参数也会自动转换。GLSL 不允许这些隐式转换，但显式写成 vec2(x)、int(x) 就可以，
/// 结果和 HLSL 的隐式转换相同。这里根据报错的行号和类型，只在出错的地方补转换：
///
/// - `'assign' : cannot convert from '…' to '<目标类型>'`、`'=' : cannot convert …`
///   → 把这一行赋值号右边包成 目标类型(…)；
/// - `'<函数名>' : no matching overloaded function found`，且函数定义在源码里
///   → 这一行调用处的每个参数包成定义里对应参数的类型；
/// - 同样的报错但是内置函数（例如 `max(0, v)`）→ 整数字面量参数改成浮点；
///   max/min 的第一个参数是字面量时和第二个对调（GLSL 只有 max(向量, 标量)，没有 max(标量, 向量)）。
public enum ImplicitConversionFixer {
    /// 修不了时返回 nil
    public static func fix(source: String, log: String) -> String? {
        var lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var changed = false
        for error in parseErrors(log) {
            let index = error.line - 1
            guard lines.indices.contains(index) else { continue }
            if let fixed = splitDeclaration(lines[index]) {
                // 一行多个声明符（`vec4 color = 0, color_2 = 0;`）先拆成多条独立声明：
                // 直接在整行上补转换会把这行改坏，拆开之后各条自己的报错就能按常规处理
                lines[index] = fixed
                changed = true
            } else if error.message.contains("cannot convert from"), let target = targetType(error.message),
               let fixed = castAssignment(lines[index], to: target) {
                lines[index] = fixed
                changed = true
            } else if error.token == "%", error.message.contains("no operation '%' exists"),
                      let fixed = rewriteModulo(lines[index]) {
                // WE 的方言按 HLSL 来，浮点也能取模；GLSL 只允许整数。改成 mod()，右边的整数转成浮点
                lines[index] = fixed
                changed = true
            } else if error.message.contains("wrong operand types"),
                      let fixed = truncateOperandsForOperator(
                          lines[index], symbol: error.token, message: error.message, in: source) {
                // HLSL 里两个不同维度的向量做二元运算时按较大的那个算，多出来的分量直接丢掉
                lines[index] = fixed
                changed = true
            } else if error.message.contains("no matching overloaded function found") {
                let fixed = parameterTypes(of: error.token, in: source)
                    .flatMap { castArguments(lines[index], function: error.token, types: $0) }
                    ?? truncateArguments(lines[index], function: error.token, in: source)
                    ?? floatLiteralArguments(lines[index], function: error.token)
                if let fixed {
                    lines[index] = fixed
                    changed = true
                }
            }
        }
        return changed ? lines.joined(separator: "\n") : nil
    }

    /// `vec4 color = 0, color_2 = 0;` → `vec4 color = 0; vec4 color_2 = 0;`
    static func splitDeclaration(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(";") else { return nil }
        let body = String(trimmed.dropLast())
        var depth = 0
        var pieces: [String] = []
        var start = body.startIndex
        for index in body.indices {
            let character = body[index]
            if "([{".contains(character) { depth += 1 }
            if ")]}".contains(character) { depth -= 1 }
            if depth == 0, character == "," {
                pieces.append(String(body[start..<index]))
                start = body.index(after: index)
            }
        }
        pieces.append(String(body[start...]))
        let types = Set([
            "float", "int", "uint", "bool", "vec2", "vec3", "vec4",
            "ivec2", "ivec3", "ivec4", "uvec2", "uvec3", "uvec4", "bvec2", "bvec3", "bvec4",
            "mat2", "mat3", "mat4",
        ])
        guard pieces.count > 1, let type = pieces[0].split(separator: " ").first.map(String.init),
              types.contains(type)
        else { return nil }
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        // 第一段里带着类型，去掉它，其余声明符只留名字和初值
        var rest = pieces
        rest[0] = pieces[0].split(separator: " ", maxSplits: 1).last.map(String.init) ?? pieces[0]
        // 每条声明单独一行：后续轮次按报错行号补转换时才不会把它们混在一起
        return rest.map { indent + "\(type) \($0.trimmingCharacters(in: .whitespaces));" }.joined(separator: "\n")
    }

    /// `A % B` → `mod(A, float(B))`。只处理一行里的第一个取模：
    /// 往两边按括号配平扫出操作数，遇到更低优先级的运算符就停
    static func rewriteModulo(_ line: String) -> String? {
        guard let percent = line.firstIndex(of: "%") else { return nil }
        let ranges = binaryOperandRanges(line, at: percent)
        let left = line[ranges.left].trimmingCharacters(in: .whitespaces)
        let right = line[ranges.right].trimmingCharacters(in: .whitespaces)
        guard !left.isEmpty, !right.isEmpty else { return nil }
        // 左操作数前面原本的空格要保留（`= frequency % x` → `= mod(frequency, …)`）；
        // 紧跟在括号后面时不用补
        let before = line[..<ranges.left.lowerBound].last
        let separator = (before == nil || before == " " || before == "(" || before == "\t") ? "" : " "
        return String(line[..<ranges.left.lowerBound]) + separator + "mod(\(left), float(\(right)))"
            + String(line[ranges.right.upperBound...])
    }

    /// HLSL 里两个不同维度的向量做二元运算时按较大的那个来，多出来的分量丢掉
    /// （`vec4 * vec2` 相当于 `v.xy * s`）；GLSL 直接报 "wrong operand types"。
    /// 从报错里读出两侧的维度，把较大的那个操作数截短。
    static func truncateOperandsForOperator(
        _ line: String, symbol: String, message: String, in source: String
    ) -> String? {
        let counts = vectorSizes(in: message)
        guard counts.count >= 2, let target = counts.min(), let longest = counts.max(),
              (2...3).contains(target), longest > target
        else { return nil }
        guard let position = firstOperatorPosition(line, symbol: symbol) else { return nil }
        let ranges = binaryOperandRanges(line, at: position)
        let left = line[ranges.left].trimmingCharacters(in: .whitespaces)
        let right = line[ranges.right].trimmingCharacters(in: .whitespaces)
        guard let leftSize = vectorSize(of: left, in: source), let rightSize = vectorSize(of: right, in: source),
              min(leftSize, rightSize) == target, max(leftSize, rightSize) == longest, leftSize != rightSize
        else { return nil }
        let suffix = target == 3 ? ".xyz" : ".xy"
        let range = leftSize > rightSize ? ranges.left : ranges.right
        // 插在操作数最后一个非空白字符之后，原来的空格全部保留（否则会写出 `a =b.xy* c`）
        var end = range.upperBound
        while end > range.lowerBound, line[line.index(before: end)].isWhitespace {
            end = line.index(before: end)
        }
        return String(line[..<end]) + suffix + String(line[end...])
    }

    /// 报错文本里出现的向量维度，例如 "… 4-component vector of float' … 2-component vector of float'"
    static func vectorSizes(in message: String) -> [Int] {
        var counts: [Int] = []
        var search = message[...]
        while let range = search.range(of: #"\d-component vector of"#, options: .regularExpression) {
            if let count = Int(search[range].prefix(1)) { counts.append(count) }
            search = search[range.upperBound...]
        }
        return counts
    }

    /// 一行里第一个处在括号外的运算符字符（`vec4 a = b * c` 里的 `*`）
    static func firstOperatorPosition(_ line: String, symbol: String) -> String.Index? {
        guard let character = symbol.first else { return nil }
        var depth = 0
        var index = line.startIndex
        while index < line.endIndex {
            let current = line[index]
            if "([{".contains(current) { depth += 1 }
            if ")]}".contains(current) { depth -= 1 }
            if depth == 0, current == character { return index }
            index = line.index(after: index)
        }
        return nil
    }

    /// 一行里某处二元运算符两侧操作数的范围：往两边按括号配平扫，遇到更低优先级的
    /// 运算符（或行首、分号、逗号）就停
    static func binaryOperandRanges(
        _ line: String, at position: String.Index
    ) -> (left: Range<String.Index>, right: Range<String.Index>) {
        let delimiters = "=+-*/,;<>"
        // 左操作数：从运算符往左扫，遇到同层的低优先级运算符或分号就停（停在下一位上）
        var leftStart = line.startIndex
        var index = line.index(before: position)
        var depth = 0
        while true {
            let character = line[index]
            if character == ")" || character == "]" { depth += 1 }
            if character == "(" || character == "[" { depth -= 1 }
            if depth < 0 { leftStart = line.index(after: index); break }
            if depth == 0, delimiters.contains(character) { leftStart = line.index(after: index); break }
            if index == line.startIndex { leftStart = index; break }
            index = line.index(before: index)
        }
        // 右操作数：从运算符往右扫
        let rightStart = line.index(after: position)
        var rightEnd = line.endIndex
        index = rightStart
        depth = 0
        while index < line.endIndex {
            let character = line[index]
            if character == "(" || character == "[" { depth += 1 }
            if character == ")" || character == "]" { depth -= 1; if depth < 0 { rightEnd = index; break } }
            if depth == 0, delimiters.contains(character) { rightEnd = index; break }
            index = line.index(after: index)
        }
        return (leftStart..<position, rightStart..<rightEnd)
    }

    /// 内置函数调用里参数维度对不上（HLSL 会自动截断，GLSL 不认）：把最长的那几个参数
    /// 截到最短的维度，例如 `mix(vec4, vec3, float)` → `mix(vec4.rgb, vec3, float)`
    static func truncateArguments(_ line: String, function: String, in source: String) -> String? {
        guard let open = line.range(of: function + "(")?.upperBound else { return nil }
        var depth = 1        // 已经吃掉了调用处的左括号
        var end = open
        while end < line.endIndex {
            let character = line[end]
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1; if depth == 0 { break } }
            end = line.index(after: end)
        }
        guard depth == 0, end > open else { return nil }
        let arguments = line[open..<end].split(separator: ",", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let sizes = arguments.map { vectorSize(of: $0, in: source) }
        let known = sizes.compactMap { $0 }
        guard known.count >= 2, let shortest = known.min(), let longest = known.max(), longest > shortest,
              (2...3).contains(shortest) else { return nil }
        let suffix = shortest == 2 ? ".xy" : ".rgb"
        let rewritten = zip(arguments, sizes).map { argument, size in
            size == longest ? argument + suffix : argument
        }
        return String(line[..<open]) + rewritten.joined(separator: ", ") + String(line[end...])
    }

    /// 表达式里那个变量的向量维度：认识 `vec3 a` 这种声明，其他（字面量、表达式）返回 nil
    static func vectorSize(of expression: String, in source: String) -> Int? {
        let name = expression.trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), !name.isEmpty else { return nil }
        let pattern = #"\b(?:i|u|b)?vec([234])\s+"# + NSRegularExpression.escapedPattern(for: name) + #"\b"#
        guard let range = source.range(of: pattern, options: .regularExpression) else { return nil }
        guard let digit = source[range].first(where: \.isNumber) else { return nil }
        return Int(String(digit))
    }

    struct CompilerError: Equatable {
        let line: Int
        let token: String
        let message: String
    }

    /// `ERROR: 0:53: 'assign' :  cannot convert from …`
    static func parseErrors(_ log: String) -> [CompilerError] {
        log.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = String(raw)
            guard let range = line.range(of: #"ERROR: \d+:(\d+): '([^']*)' :\s*(.*)"#, options: .regularExpression) else { return nil }
            let body = String(line[range]).dropFirst("ERROR: ".count)
            let parts = body.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let number = Int(parts[1]) else { return nil }
            let rest = parts[2].trimmingCharacters(in: .whitespaces)
            guard rest.hasPrefix("'"), let close = rest.dropFirst().firstIndex(of: "'") else { return nil }
            let token = String(rest[rest.index(after: rest.startIndex)..<close])
            let message = rest[rest.index(after: close)...].trimmingCharacters(in: CharacterSet(charactersIn: " :"))
            return CompilerError(line: number, token: token, message: message)
        }
    }

    /// 从 "cannot convert from 'A' to 'B'" 里取 B，翻成 GLSL 类型名
    static func targetType(_ message: String) -> String? {
        guard let to = message.range(of: "' to '") else { return nil }
        let description = message[to.upperBound...].prefix { $0 != "'" }
        return glslType(String(description))
    }

    /// glslang 报错里的类型描述 → GLSL 类型名，例如 "smooth out highp 2-component vector of float" → vec2
    static func glslType(_ description: String) -> String? {
        let words = description.split(separator: " ").map(String.init)
        guard let base = words.last else { return nil }
        let prefix: String
        switch base {
        case "float": prefix = ""
        case "int": prefix = "i"
        case "uint": prefix = "u"
        case "bool": prefix = "b"
        default: return nil
        }
        if let range = description.range(of: #"(\d)-component vector of"#, options: .regularExpression),
           let count = Int(description[range].prefix(1)) {
            return "\(prefix)vec\(count)"
        }
        return base
    }

    /// `lhs = rhs;` → `lhs = T(rhs);`，也处理 `+=` 这类复合赋值。
    /// `for (int i = x; …)` 只改初始化部分；其他一行里有多条语句的情况不动
    static func castAssignment(_ line: String, to type: String) -> String? {
        let isForLoop = line.trimmingCharacters(in: .whitespaces).hasPrefix("for")
        guard let semicolon = isForLoop ? line.firstIndex(of: ";") : line.lastIndex(of: ";"),
              isForLoop || line.filter({ $0 == ";" }).count == 1
        else { return nil }
        var index = line.startIndex
        var assignment: String.Index?
        while index < semicolon {
            if line[index] == "=" {
                let next = line.index(after: index)
                let previous = index > line.startIndex ? line[line.index(before: index)] : " "
                let isComparison = (next < line.endIndex && line[next] == "=") || "=!<>".contains(previous)
                if !isComparison {
                    assignment = index
                    break
                }
                if next < line.endIndex && line[next] == "=" { index = next }
            }
            index = line.index(after: index)
        }
        guard let assignment else { return nil }
        let valueStart = line.index(after: assignment)
        let value = line[valueStart..<semicolon].trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        return String(line[..<valueStart]) + " \(type)(\(value))" + String(line[semicolon...])
    }

    /// 源码里函数定义的参数类型，例如 `vec2 rotateVec2(vec2 v, float r)` → ["vec2", "float"]
    static func parameterTypes(of function: String, in source: String) -> [String]? {
        let pattern = #"\b\w+\s+"# + NSRegularExpression.escapedPattern(for: function) + #"\s*\(([^)]*)\)\s*\{?"#
        guard let range = source.range(of: pattern, options: .regularExpression) else { return nil }
        let signature = source[range]
        guard let open = signature.firstIndex(of: "("), let close = signature.lastIndex(of: ")") else { return nil }
        let parameters = signature[signature.index(after: open)..<close].split(separator: ",")
        let types = parameters.compactMap { parameter -> String? in
            let words = parameter.split(separator: " ").map(String.init).filter { !["in", "const", "highp", "mediump", "lowp"].contains($0) }
            return words.count >= 2 ? words[0] : nil
        }
        return types.count == parameters.count && !types.isEmpty ? types : nil
    }

    /// 这一行里第一处 function( … ) 的每个参数包上对应类型
    static func castArguments(_ line: String, function: String, types: [String]) -> String? {
        guard let call = splitCall(line, function: function), call.arguments.count == types.count else { return nil }
        let arguments = zip(types, call.arguments).map { "\($0)(\($1.trimmingCharacters(in: .whitespaces)))" }
        return call.before + arguments.joined(separator: ", ") + call.after
    }

    /// 内置函数：整数字面量参数改成浮点；max/min 的第一个参数是字面量时和第二个对调
    static func floatLiteralArguments(_ line: String, function: String) -> String? {
        guard let call = splitCall(line, function: function) else { return nil }
        let isLiteral = { (text: String) in text.range(of: #"^-?\d+(\.\d*)?$"#, options: .regularExpression) != nil }
        var arguments = call.arguments.map { argument -> String in
            let trimmed = argument.trimmingCharacters(in: .whitespaces)
            return trimmed.range(of: #"^-?\d+$"#, options: .regularExpression) != nil ? trimmed + ".0" : trimmed
        }
        if ["max", "min"].contains(function), arguments.count == 2, isLiteral(arguments[0]), !isLiteral(arguments[1]) {
            arguments.swapAt(0, 1)
        }
        let rebuilt = call.before + arguments.joined(separator: ", ") + call.after
        return rebuilt == line ? nil : rebuilt
    }

    /// 把一行里第一处 function( … ) 拆成调用之前的部分、顶层逗号分开的参数、右括号及之后的部分
    private static func splitCall(_ line: String, function: String) -> (before: String, arguments: [String], after: String)? {
        guard let call = line.range(of: function + "("), !line[..<call.lowerBound].hasSuffix("_") else { return nil }
        var depth = 0
        var arguments: [String] = []
        var current = ""
        var end: String.Index?
        var index = call.upperBound
        while index < line.endIndex {
            let character = line[index]
            if character == "(" { depth += 1 }
            if character == ")" {
                if depth == 0 {
                    end = index
                    break
                }
                depth -= 1
            }
            if character == "," && depth == 0 {
                arguments.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index = line.index(after: index)
        }
        arguments.append(current)
        guard let end else { return nil }
        return (String(line[..<call.upperBound]), arguments, String(line[end...]))
    }
}
