import Foundation
import InnoNetwork

struct Product: Decodable, Sendable {
    let id: Int
    let name: String
    let price: Decimal
}

struct ProductSearchResult: Decodable, Sendable {
    let items: [Product]
}

struct OrderReceipt: Decodable, Sendable {
    let id: String
    let status: String
}

struct ListProducts: APIDefinition {
    var sessionAuthentication: SessionAuthentication { .anonymous }
    typealias Parameter = EmptyParameter
    typealias APIResponse = [Product]

    var method: HTTPMethod { .get }
    var path: String { "/products" }
}

struct GetProduct: APIDefinition {
    var sessionAuthentication: SessionAuthentication { .anonymous }
    typealias Parameter = EmptyParameter
    typealias APIResponse = Product

    let id: Int

    var method: HTTPMethod { .get }
    var path: String { "/products/\(id)" }
}

struct SearchProducts: APIDefinition {
    var sessionAuthentication: SessionAuthentication { .anonymous }
    struct Query: Encodable, Sendable {
        let query: String
        let limit: Int
    }

    typealias Parameter = Query
    typealias APIResponse = ProductSearchResult

    let parameters: Query?

    var method: HTTPMethod { .get }
    var path: String { "/products/search" }

    init(query: String, limit: Int = 20) {
        parameters = Query(query: query, limit: limit)
    }
}

struct CreateOrder: APIDefinition {
    var sessionAuthentication: SessionAuthentication { .anonymous }
    struct Body: Encodable, Sendable {
        let productID: Int
        let quantity: Int
    }

    typealias Parameter = Body
    typealias APIResponse = OrderReceipt

    let parameters: Body?

    var method: HTTPMethod { .post }
    var path: String { "/orders" }

    init(productID: Int, quantity: Int) {
        parameters = Body(productID: productID, quantity: quantity)
    }
}

enum CatalogTarget: Sendable {
    case listProducts
    case product(id: Int)
    case search(query: String, limit: Int = 20)
    case createOrder(productID: Int, quantity: Int)

    func send(using client: DefaultNetworkClient) async throws(NetworkError) -> CatalogTargetResult {
        switch self {
        case .listProducts:
            return .products(try await client.request(ListProducts()))
        case .product(let id):
            return .product(try await client.request(GetProduct(id: id)))
        case .search(let query, let limit):
            return .search(try await client.request(SearchProducts(query: query, limit: limit)))
        case .createOrder(let productID, let quantity):
            return .orderReceipt(try await client.request(CreateOrder(productID: productID, quantity: quantity)))
        }
    }
}

enum CatalogTargetResult: Sendable {
    case products([Product])
    case product(Product)
    case search(ProductSearchResult)
    case orderReceipt(OrderReceipt)
}
