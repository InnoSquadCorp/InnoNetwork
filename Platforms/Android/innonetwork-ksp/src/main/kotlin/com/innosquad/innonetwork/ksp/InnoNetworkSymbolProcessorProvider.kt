package com.innosquad.innonetwork.ksp

import com.google.devtools.ksp.processing.SymbolProcessor
import com.google.devtools.ksp.processing.SymbolProcessorEnvironment
import com.google.devtools.ksp.processing.SymbolProcessorProvider

/** Service-loaded entry point for the optional InnoNetwork endpoint generator. */
public class InnoNetworkSymbolProcessorProvider : SymbolProcessorProvider {
    override fun create(environment: SymbolProcessorEnvironment): SymbolProcessor =
        InnoNetworkSymbolProcessor(environment.codeGenerator, environment.logger)
}
