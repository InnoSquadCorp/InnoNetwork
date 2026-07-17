import SwiftDiagnostics
import SwiftSyntax

extension APIDefinitionMacro {
    enum Authentication {
        case anonymous
        case optional
        case required

        var caseName: String {
            switch self {
            case .anonymous: return "anonymous"
            case .optional: return "optional"
            case .required: return "required"
            }
        }
    }

    enum MethodKind {
        case queryOnly(name: String)
        case body
        case requiresExplicitPayload
    }

    static func authentication(from argument: LabeledExprSyntax) throws -> Authentication {
        switch explicitMemberName(
            from: argument.expression,
            allowedQualifiedBases: [
                "SessionAuthentication",
                "InnoNetwork.SessionAuthentication",
            ]
        ) {
        case "anonymous":
            return .anonymous
        case "optional":
            return .optional
        case "required":
            return .required
        default:
            throw InnoNetworkMacroDiagnostic(
                "@APIDefinition auth: must be .anonymous, .optional, or .required, optionally qualified by SessionAuthentication or InnoNetwork.SessionAuthentication.",
                id: "api-definition-invalid-auth"
            ).error(at: argument.expression)
        }
    }

    static func argumentList(from node: AttributeSyntax) throws -> LabeledExprListSyntax {
        guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else {
            throw InnoNetworkMacroDiagnostic(
                "@APIDefinition requires labeled arguments: method and path.",
                id: "api-definition-missing-arguments"
            ).error(at: node)
        }
        return arguments
    }

    static func requiredArgument(
        named name: String,
        in arguments: LabeledExprListSyntax
    ) throws -> LabeledExprSyntax {
        guard let argument = arguments.first(where: { $0.label?.text == name }) else {
            throw InnoNetworkMacroDiagnostic(
                "@APIDefinition requires a \(name): argument.",
                id: "api-definition-missing-\(name)"
            ).error(at: arguments)
        }
        return argument
    }

    static func stringLiteralArgument(
        named name: String,
        in arguments: LabeledExprListSyntax
    ) throws -> String {
        let argument = try requiredArgument(named: name, in: arguments)
        guard let literal = argument.expression.as(StringLiteralExprSyntax.self) else {
            throw InnoNetworkMacroDiagnostic(
                "@APIDefinition \(name): must be a static string literal.",
                id: "api-definition-nonliteral-\(name)"
            ).error(at: argument.expression)
        }
        guard literal.openingPounds == nil, literal.openingQuote.text == "\"" else {
            throw InnoNetworkMacroDiagnostic(
                "@APIDefinition \(name): must use a single-line non-raw string literal; raw and multiline literals are not supported.",
                id: "api-definition-unsupported-literal-\(name)"
            ).error(at: argument.expression)
        }

        var value = ""
        for segment in literal.segments {
            guard let stringSegment = segment.as(StringSegmentSyntax.self) else {
                let fixIts = interpolationToPlaceholderFixIts(segment)
                throw InnoNetworkMacroDiagnostic(
                    "@APIDefinition \(name): does not support string interpolation.",
                    id: "api-definition-interpolated-\(name)"
                ).error(at: segment, fixIts: fixIts)
            }
            value += stringSegment.content.text
        }
        return value
    }

    static func interpolationToPlaceholderFixIts(
        _ segment: StringLiteralSegmentListSyntax.Element
    ) -> [FixIt] {
        guard let expressionSegment = segment.as(ExpressionSegmentSyntax.self),
            expressionSegment.expressions.count == 1,
            let onlyExpression = expressionSegment.expressions.first,
            onlyExpression.label == nil,
            let identifier = onlyExpression.expression.as(DeclReferenceExprSyntax.self)?
                .baseName.text
        else {
            return []
        }
        let replacement = StringSegmentSyntax(
            content: .stringSegment("{\(identifier)}")
        )
        return [
            FixIt(
                message: InnoNetworkMacroFixItMessage(
                    "Replace string interpolation with '{\(identifier)}' path placeholder.",
                    id: "api-definition-replace-interpolation"
                ),
                changes: [
                    .replace(
                        oldNode: Syntax(segment),
                        newNode: Syntax(replacement)
                    )
                ]
            )
        ]
    }

    static func methodKind(_ method: ExprSyntax) -> MethodKind {
        switch explicitHTTPMethodName(from: method) {
        case "get":
            return .queryOnly(name: "GET")
        case "head":
            return .queryOnly(name: "HEAD")
        case "post", "put", "patch", "delete":
            return .body
        default:
            return .requiresExplicitPayload
        }
    }

    static let simplePayloadMethodDiagnostic =
        "@APIDefinition simple body/query inference requires method: to be .get, .head, .post, .put, .patch, or .delete, optionally qualified by HTTPMethod or InnoNetwork.HTTPMethod; use a complete Parameter + parameters fallback for OPTIONS, CONNECT, TRACE, custom, or dynamic methods."

    static func canonicalMethodExpression(from expression: ExprSyntax) -> String {
        guard let name = explicitHTTPMethodName(from: expression) else {
            return expression.trimmedDescription
        }
        return ".\(name)"
    }

    static func explicitHTTPMethodName(from expression: ExprSyntax) -> String? {
        explicitMemberName(
            from: expression,
            allowedQualifiedBases: ["HTTPMethod", "InnoNetwork.HTTPMethod"]
        )
    }

    static func explicitMemberName(
        from expression: ExprSyntax,
        allowedQualifiedBases: Set<String>
    ) -> String? {
        guard let member = expression.as(MemberAccessExprSyntax.self) else {
            return nil
        }
        if let base = member.base,
            !allowedQualifiedBases.contains(base.trimmedDescription)
        {
            return nil
        }
        return member.declName.baseName.text
    }
}
