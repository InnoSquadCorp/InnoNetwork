package com.innosquad.innonetwork.ksp

import com.google.devtools.ksp.getDeclaredProperties
import com.google.devtools.ksp.processing.CodeGenerator
import com.google.devtools.ksp.processing.Dependencies
import com.google.devtools.ksp.processing.KSPLogger
import com.google.devtools.ksp.processing.Resolver
import com.google.devtools.ksp.processing.SymbolProcessor
import com.google.devtools.ksp.symbol.ClassKind
import com.google.devtools.ksp.symbol.KSAnnotated
import com.google.devtools.ksp.symbol.KSAnnotation
import com.google.devtools.ksp.symbol.KSClassDeclaration
import com.google.devtools.ksp.symbol.KSPropertyDeclaration
import com.google.devtools.ksp.symbol.KSType
import com.google.devtools.ksp.symbol.Modifier
import com.google.devtools.ksp.symbol.Nullability
import com.google.devtools.ksp.validate

internal class InnoNetworkSymbolProcessor(
    private val codeGenerator: CodeGenerator,
    private val logger: KSPLogger,
) : SymbolProcessor {
    private val generatedTypes: MutableSet<String> = mutableSetOf()

    override fun process(resolver: Resolver): List<KSAnnotated> {
        val symbols = resolver.getSymbolsWithAnnotation(ENDPOINT_ANNOTATION).toList()
        val deferred = symbols.filterNot { it.validate() }

        symbols.asSequence()
            .filter { it.validate() }
            .forEach { symbol ->
                val declaration = symbol as? KSClassDeclaration
                if (declaration == null) {
                    logger.error("$DIAGNOSTIC_PREFIX @InnoEndpoint can annotate classes only", symbol)
                    return@forEach
                }
                generate(declaration, resolver)
            }

        return deferred
    }

    private fun generate(declaration: KSClassDeclaration, resolver: Resolver) {
        val qualifiedName = declaration.qualifiedName?.asString()
        if (qualifiedName == null || !generatedTypes.add(qualifiedName)) {
            return
        }
        if (declaration.classKind != ClassKind.CLASS || Modifier.ABSTRACT in declaration.modifiers) {
            logger.error("$DIAGNOSTIC_PREFIX endpoint must be a concrete class", declaration)
            return
        }
        if (Modifier.PRIVATE in declaration.modifiers || Modifier.PROTECTED in declaration.modifiers) {
            logger.error("$DIAGNOSTIC_PREFIX endpoint must be public or internal", declaration)
            return
        }
        if (declaration.parentDeclaration != null) {
            logger.error("$DIAGNOSTIC_PREFIX nested endpoint classes are not supported", declaration)
            return
        }
        if (declaration.typeParameters.isNotEmpty()) {
            logger.error("$DIAGNOSTIC_PREFIX generic endpoint classes are not supported", declaration)
            return
        }

        val endpointName = declaration.simpleName.asString()
        if (!KOTLIN_IDENTIFIER.matches(endpointName)) {
            logger.error("$DIAGNOSTIC_PREFIX endpoint name must be a plain Kotlin identifier", declaration)
            return
        }
        val endpointAnnotation = declaration.annotation(ENDPOINT_ANNOTATION)
        if (endpointAnnotation == null) {
            logger.error("$DIAGNOSTIC_PREFIX endpoint annotation could not be resolved", declaration)
            return
        }
        val method = endpointAnnotation.stringArgument("method")
        val rawPath = endpointAnnotation.stringArgument("path")
        if (method == null || !HTTP_METHOD.matches(method)) {
            logger.error("$DIAGNOSTIC_PREFIX method must be a valid uppercase HTTP token", declaration)
            return
        }
        if (rawPath == null) {
            logger.error("$DIAGNOSTIC_PREFIX path is required", declaration)
            return
        }

        val pathTemplate = PathTemplate.parse(rawPath).getOrElse { error ->
            logger.error("$DIAGNOSTIC_PREFIX ${error.message}", declaration)
            return
        }
        val properties = declaration.getDeclaredProperties().toList()
        val requestBodyType = resolver.getClassDeclarationByName(resolver.getKSNameFromString(REQUEST_BODY_TYPE))
            ?.asStarProjectedType()
        val model = endpointModel(declaration, method, pathTemplate, properties, requestBodyType) ?: return
        val sourceFile = declaration.containingFile
        if (sourceFile == null) {
            logger.error("$DIAGNOSTIC_PREFIX endpoint must originate from a source file", declaration)
            return
        }

        val packageName = declaration.packageName.asString()
        val fileName = "${endpointName}InnoNetwork"
        codeGenerator.createNewFile(
            dependencies = Dependencies(aggregating = false, sourceFile),
            packageName = packageName,
            fileName = fileName,
        ).bufferedWriter().use { writer ->
            writer.write(render(packageName, endpointName, model, declaration.visibilityKeyword()))
        }
    }

    private fun endpointModel(
        declaration: KSClassDeclaration,
        method: String,
        pathTemplate: PathTemplate,
        properties: List<KSPropertyDeclaration>,
        requestBodyType: KSType?,
    ): EndpointModel? {
        val pathProperties = mutableMapOf<String, PropertyModel>()
        val queries = mutableListOf<NamedPropertyModel>()
        val headers = mutableListOf<NamedPropertyModel>()
        val headerNames = mutableSetOf<String>()
        var body: PropertyModel? = null
        var valid = true

        properties.forEach { property ->
            val roles = listOf(
                PATH_ANNOTATION to property.annotation(PATH_ANNOTATION),
                QUERY_ANNOTATION to property.annotation(QUERY_ANNOTATION),
                HEADER_ANNOTATION to property.annotation(HEADER_ANNOTATION),
                BODY_ANNOTATION to property.annotation(BODY_ANNOTATION),
            ).filter { it.second != null }
            if (roles.size > 1) {
                logger.error("$DIAGNOSTIC_PREFIX a property may have only one endpoint role", property)
                valid = false
                return@forEach
            }
            if (roles.isEmpty()) {
                return@forEach
            }
            if (Modifier.PRIVATE in property.modifiers || Modifier.PROTECTED in property.modifiers) {
                logger.error("$DIAGNOSTIC_PREFIX endpoint properties must be public or internal", property)
                valid = false
                return@forEach
            }

            val propertyModel = property.toModel()
            when (roles.single().first) {
                PATH_ANNOTATION -> {
                    if (propertyModel.nullable) {
                        logger.error("$DIAGNOSTIC_PREFIX path properties must be non-null", property)
                        valid = false
                    }
                    if (!property.isSupportedScalar()) {
                        logger.error("$DIAGNOSTIC_PREFIX path properties must be scalar values", property)
                        valid = false
                    }
                    pathProperties[propertyModel.name] = propertyModel
                }

                QUERY_ANNOTATION -> {
                    if (!property.isSupportedScalar()) {
                        logger.error("$DIAGNOSTIC_PREFIX query properties must be scalar values", property)
                        valid = false
                    }
                    val wireName = roles.single().second?.stringArgument("name")
                        ?.takeIf { it.isNotEmpty() } ?: propertyModel.name
                    queries += NamedPropertyModel(wireName, propertyModel)
                }

                HEADER_ANNOTATION -> {
                    if (!property.isSupportedScalar()) {
                        logger.error("$DIAGNOSTIC_PREFIX header properties must be scalar values", property)
                        valid = false
                    }
                    val wireName = roles.single().second?.stringArgument("name")
                        ?.takeIf { it.isNotEmpty() } ?: propertyModel.name
                    if (!wireName.isValidHeaderName()) {
                        logger.error("$DIAGNOSTIC_PREFIX header names must be valid HTTP field names", property)
                        valid = false
                    }
                    if (!headerNames.add(wireName.lowercase())) {
                        logger.error(
                            "$DIAGNOSTIC_PREFIX duplicate header name: $wireName",
                            property,
                        )
                        valid = false
                    }
                    headers += NamedPropertyModel(wireName, propertyModel)
                }

                BODY_ANNOTATION -> {
                    if (body != null) {
                        logger.error("$DIAGNOSTIC_PREFIX only one request body is supported", property)
                        valid = false
                    }
                    if (requestBodyType?.isAssignableFrom(property.type.resolve().makeNotNullable()) != true) {
                        logger.error("$DIAGNOSTIC_PREFIX body must have type okhttp3.RequestBody", property)
                        valid = false
                    }
                    if (propertyModel.nullable && method in BODY_REQUIRED_METHODS) {
                        logger.error(
                            "$DIAGNOSTIC_PREFIX $method @InnoBody properties must be non-null",
                            property,
                        )
                        valid = false
                    }
                    body = propertyModel
                }
            }
        }

        val missingPaths = pathTemplate.placeholders - pathProperties.keys
        val unusedPaths = pathProperties.keys - pathTemplate.placeholders
        if (missingPaths.isNotEmpty()) {
            logger.error(
                "$DIAGNOSTIC_PREFIX missing @InnoPath properties: ${missingPaths.sorted().joinToString()}",
                declaration,
            )
            valid = false
        }
        if (unusedPaths.isNotEmpty()) {
            logger.error(
                "$DIAGNOSTIC_PREFIX unused @InnoPath properties: ${unusedPaths.sorted().joinToString()}",
                declaration,
            )
            valid = false
        }
        if (body != null && method in BODY_FORBIDDEN_METHODS) {
            logger.error("$DIAGNOSTIC_PREFIX $method requests cannot declare @InnoBody", declaration)
            valid = false
        }
        if (!valid) {
            return null
        }
        return EndpointModel(method, pathTemplate, pathProperties, queries, headers, body)
    }

    private fun render(
        packageName: String,
        endpointName: String,
        model: EndpointModel,
        visibility: String,
    ): String = buildString {
        val endpointType = endpointName.identifier()
        val outputType = if (endpointName == "Output") "EndpointOutput" else "Output"
        val generatedType = "${endpointName}GeneratedAPIDefinition".identifier()
        fun alias(name: String): String =
            if (endpointName == "InnoNetwork$name") "InnoNetwork${name}_Type" else "InnoNetwork$name"
        val requestType = alias("NativeRequest")
        val urlType = alias("NativeHttpUrl")
        val responseType = alias("DataResponse")
        val definitionType = alias("Definition")
        val intType = alias("Int")
        val booleanType = alias("Boolean")
        val byteArrayType = alias("ByteArray")
        val requireFunction = alias("Require")
        if (packageName.isNotEmpty()) {
            appendLine("package ${packageName.split('.').joinToString(".") { it.identifier() }}")
            appendLine()
        }
        appendLine("import com.innosquad.innonetwork.NetworkDataResponse as $responseType")
        appendLine("import com.innosquad.innonetwork.client.APIDefinition as $definitionType")
        appendLine("import okhttp3.HttpUrl as $urlType")
        appendLine("import okhttp3.Request as $requestType")
        appendLine("import kotlin.Int as $intType")
        appendLine("import kotlin.Boolean as $booleanType")
        if (model.pathProperties.isNotEmpty()) {
            appendLine("import kotlin.require as $requireFunction")
        }
        if (model.body == null && model.method in BODY_REQUIRED_METHODS) {
            appendLine("import kotlin.ByteArray as $byteArrayType")
            appendLine("import okhttp3.RequestBody.Companion.toRequestBody")
        }
        appendLine()
        appendLine("/** Generated native request adapter for [$endpointName]. */")
        appendLine("$visibility fun <$outputType> $endpointType.apiDefinition(")
        appendLine("    acceptsStatusCode: ($intType) -> $booleanType = { it in 200..299 },")
        appendLine("    decoder: ($responseType) -> $outputType,")
        appendLine("): $definitionType<$outputType> = $generatedType(")
        appendLine("    endpoint = this,")
        appendLine("    acceptsStatusCode = acceptsStatusCode,")
        appendLine("    decoder = decoder,")
        appendLine(")")
        appendLine()
        appendLine("private class $generatedType<$outputType>(")
        appendLine("    private val endpoint: $endpointType,")
        appendLine("    private val acceptsStatusCode: ($intType) -> $booleanType,")
        appendLine("    private val decoder: ($responseType) -> $outputType,")
        appendLine(") : $definitionType<$outputType> {")
        appendLine("    override fun request(baseUrl: $urlType): $requestType {")
        appendLine("        val urlBuilder = baseUrl.newBuilder()")
        model.pathTemplate.segments.forEachIndexed { index, segment ->
            when (segment) {
                is PathSegment.Literal -> appendLine(
                    "        urlBuilder.addPathSegment(${segment.value.kotlinString()})",
                )
                is PathSegment.Placeholder -> {
                    val property = model.pathProperties.getValue(segment.propertyName)
                    val propertyAccess = "endpoint.${segment.propertyName.identifier()}"
                    val localName = "pathSegment$index"
                    appendLine(
                        "        val $localName = ${property.stringExpression(propertyAccess)}",
                    )
                    appendLine(
                        "        $requireFunction($localName != \".\" && $localName != \"..\") {",
                    )
                    appendLine(
                        "            \"@InnoPath ${segment.propertyName} must not resolve to a dot segment\"",
                    )
                    appendLine("        }")
                    appendLine(
                        "        urlBuilder.addPathSegment($localName)",
                    )
                }
            }
        }
        model.queries.forEach { query ->
            appendNamedValue("urlBuilder.addQueryParameter", query)
        }
        appendLine("        val requestBuilder = $requestType.Builder().url(urlBuilder.build())")
        model.headers.forEach { header ->
            appendNamedValue("requestBuilder.header", header)
        }
        val bodyExpression = when {
            model.body != null -> "endpoint.${model.body.name.identifier()}"
            model.method in BODY_REQUIRED_METHODS -> "$byteArrayType(0).toRequestBody(null)"
            else -> "null"
        }
        appendLine(
            "        return requestBuilder.method(${model.method.kotlinString()}, $bodyExpression).build()",
        )
        appendLine("    }")
        appendLine()
        appendLine("    override fun acceptsStatusCode(statusCode: $intType): $booleanType =")
        appendLine("        acceptsStatusCode.invoke(statusCode)")
        appendLine()
        appendLine(
            "    override fun decode(response: $responseType): $outputType = decoder(response)",
        )
        appendLine("}")
    }

    private fun StringBuilder.appendNamedValue(
        call: String,
        namedProperty: NamedPropertyModel,
    ) {
        val wireName = namedProperty.wireName.kotlinString()
        val propertyAccess = "endpoint.${namedProperty.property.name.identifier()}"
        if (namedProperty.property.nullable) {
            appendLine("        $propertyAccess?.let { value ->")
            appendLine("            $call($wireName, ${namedProperty.property.stringExpression("value")})")
            appendLine("        }")
        } else {
            appendLine(
                "        $call($wireName, ${namedProperty.property.stringExpression(propertyAccess)})",
            )
        }
    }

    private fun KSPropertyDeclaration.toModel(): PropertyModel {
        val resolvedType = type.resolve()
        return PropertyModel(
            name = simpleName.asString(),
            nullable = resolvedType.nullability == Nullability.NULLABLE,
            isString = resolvedType.declaration.qualifiedName?.asString() == STRING_TYPE,
        )
    }

    private fun KSPropertyDeclaration.isSupportedScalar(): Boolean {
        val declaration = type.resolve().declaration
        val qualifiedName = declaration.qualifiedName?.asString()
        return qualifiedName in SCALAR_TYPES ||
            (declaration as? KSClassDeclaration)?.classKind == ClassKind.ENUM_CLASS
    }

    private fun KSClassDeclaration.visibilityKeyword(): String =
        if (Modifier.PUBLIC in modifiers) "public" else "internal"

    private fun KSAnnotated.annotation(qualifiedName: String): KSAnnotation? =
        annotations.firstOrNull {
            it.annotationType.resolve().declaration.qualifiedName?.asString() == qualifiedName
        }

    private fun KSAnnotation.stringArgument(name: String): String? =
        arguments.firstOrNull { it.name?.asString() == name }?.value as? String

    private fun String.identifier(): String = "`$this`"

    private fun String.isValidHeaderName(): Boolean =
        isNotEmpty() && all { character ->
            when (character) {
                in 'A'..'Z',
                in 'a'..'z',
                in '0'..'9',
                '!',
                '#',
                '$',
                '%',
                '&',
                '\'',
                '*',
                '+',
                '-',
                '.',
                '^',
                '_',
                '`',
                '|',
                '~',
                -> true
                else -> false
            }
        }

    private fun String.kotlinString(): String = buildString {
        append('"')
        this@kotlinString.forEach { character ->
            when (character) {
                '\\' -> append("\\\\")
                '"' -> append("\\\"")
                '$' -> append("\\$")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else -> if (character.code < 0x20) {
                    append("\\u%04x".format(character.code))
                } else {
                    append(character)
                }
            }
        }
        append('"')
    }

    private data class EndpointModel(
        val method: String,
        val pathTemplate: PathTemplate,
        val pathProperties: Map<String, PropertyModel>,
        val queries: List<NamedPropertyModel>,
        val headers: List<NamedPropertyModel>,
        val body: PropertyModel?,
    )

    private data class PropertyModel(
        val name: String,
        val nullable: Boolean,
        val isString: Boolean,
    ) {
        fun stringExpression(value: String): String = if (isString) value else "$value.toString()"
    }

    private data class NamedPropertyModel(
        val wireName: String,
        val property: PropertyModel,
    )

    private companion object {
        private const val DIAGNOSTIC_PREFIX: String = "[InnoNetwork]"
        private const val STRING_TYPE: String = "kotlin.String"
        private const val ENDPOINT_ANNOTATION: String =
            "com.innosquad.innonetwork.client.codegen.InnoEndpoint"
        private const val PATH_ANNOTATION: String =
            "com.innosquad.innonetwork.client.codegen.InnoPath"
        private const val QUERY_ANNOTATION: String =
            "com.innosquad.innonetwork.client.codegen.InnoQuery"
        private const val HEADER_ANNOTATION: String =
            "com.innosquad.innonetwork.client.codegen.InnoHeader"
        private const val BODY_ANNOTATION: String =
            "com.innosquad.innonetwork.client.codegen.InnoBody"
        private const val REQUEST_BODY_TYPE: String = "okhttp3.RequestBody"

        private val KOTLIN_IDENTIFIER: Regex = Regex("[A-Za-z_][A-Za-z0-9_]*")
        private val HTTP_METHOD: Regex = Regex("[A-Z0-9!#" + '$' + "%&'*+.^_`|~-]+")
        private val BODY_FORBIDDEN_METHODS: Set<String> = setOf("GET", "HEAD")
        private val BODY_REQUIRED_METHODS: Set<String> = setOf(
            "POST",
            "PUT",
            "PATCH",
            "PROPPATCH",
            "QUERY",
            "REPORT",
        )
        private val SCALAR_TYPES: Set<String> = setOf(
            "kotlin.String",
            "kotlin.Boolean",
            "kotlin.Byte",
            "kotlin.Short",
            "kotlin.Int",
            "kotlin.Long",
            "kotlin.Float",
            "kotlin.Double",
            "kotlin.Char",
            "kotlin.UByte",
            "kotlin.UShort",
            "kotlin.UInt",
            "kotlin.ULong",
        )
    }
}
