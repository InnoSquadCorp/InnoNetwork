import com.innosquad.innonetwork.consumersmoke.`when`.Output
import com.innosquad.innonetwork.consumersmoke.`when`.Int as IntEndpoint
import com.innosquad.innonetwork.consumersmoke.`when`.com as PackageNameEndpoint
import com.innosquad.innonetwork.consumersmoke.`when`.InnoNetworkNativeRequest
import com.innosquad.innonetwork.consumersmoke.`when`.Request
import com.innosquad.innonetwork.consumersmoke.`when`.Response
import com.innosquad.innonetwork.consumersmoke.`when`.TrailingSlashEndpoint
import com.innosquad.innonetwork.consumersmoke.`when`.`class`
import com.innosquad.innonetwork.consumersmoke.`when`.apiDefinition as namedDefinition
import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Test

public class EndpointNamesTest {
    @Test
    public fun defaultPackageEndpointsCompileAndBuildRequests(): Unit {
        val request = RootEndpoint().apiDefinition { it.statusCode }
            .request("https://example.com/api/".toHttpUrl())

        assertEquals("/api/root", request.url.encodedPath)
    }

    @Test
    public fun keywordPackagesAndNativeTypeNamesDoNotCollideWithGeneratedTypes(): Unit {
        val base = "https://example.com/api/".toHttpUrl()

        assertEquals("/api/request", Request().namedDefinition { it.statusCode }.request(base).url.encodedPath)
        assertEquals("/api/response", Response().namedDefinition { it.statusCode }.request(base).url.encodedPath)
        assertEquals("/api/output", Output().namedDefinition { it.statusCode }.request(base).url.encodedPath)
        assertEquals("/api/keyword", `class`().namedDefinition { it.statusCode }.request(base).url.encodedPath)
        assertEquals("/api/int", IntEndpoint().namedDefinition { it.statusCode }.request(base).url.encodedPath)
        assertEquals("/api/package-name", PackageNameEndpoint().namedDefinition { it.statusCode }.request(base).url.encodedPath)
        assertEquals("/api/alias-name", InnoNetworkNativeRequest().namedDefinition { it.statusCode }.request(base).url.encodedPath)
    }

    @Test
    public fun generatedPathsPreserveTheRequiredTrailingSlash(): Unit {
        val request = TrailingSlashEndpoint().namedDefinition { it.statusCode }
            .request("https://example.com/api/".toHttpUrl())

        assertEquals("/api/messages/", request.url.encodedPath)
    }
}
