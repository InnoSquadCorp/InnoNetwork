//
//  BasicRequestExample.swift
//  InnoNetwork Examples
//
//  This file demonstrates basic HTTP request usage with InnoNetwork.
//  GET, POST, PUT, DELETE requests using JSONPlaceholder API.
//

import Foundation
import InnoNetwork

// MARK: - 1. Data Models

struct Todo: Decodable, Sendable {
    let id: Int
    let title: String
    let completed: Bool
    let userId: Int
}

struct Post: Codable, Sendable {
    let id: Int?
    let title: String
    let body: String
    let userId: Int
}

// MARK: - 2. API Definitions

@APIDefinition(method: .get, path: "/todos", auth: .anonymous)
struct GetTodos {
    typealias APIResponse = [Todo]
}

@APIDefinition(method: .get, path: "/posts/{postId}", auth: .anonymous)
struct GetPost {
    typealias APIResponse = Post

    let postId: Int
}

@APIDefinition(method: .post, path: "/posts", auth: .anonymous)
struct CreatePost {
    struct PostParameter: Encodable, Sendable {
        let title: String
        let body: String
        let userId: Int
    }

    typealias APIResponse = Post

    let body: PostParameter

    init(title: String, body: String, userId: Int = 1) {
        self.body = PostParameter(title: title, body: body, userId: userId)
    }
}

@APIDefinition(method: .put, path: "/posts/{postId}", auth: .anonymous)
struct UpdatePost {
    struct PostParameter: Encodable, Sendable {
        let id: Int
        let title: String
        let body: String
        let userId: Int
    }

    typealias APIResponse = Post

    let postId: Int
    let body: PostParameter

    init(id: Int, title: String, body: String, userId: Int = 1) {
        self.postId = id
        self.body = PostParameter(id: id, title: title, body: body, userId: userId)
    }
}

@APIDefinition(method: .patch, path: "/posts/1", auth: .anonymous)
struct PatchPost {
    struct PostParameter: Encodable, Sendable {
        let title: String?
        let body: String?
    }

    typealias APIResponse = Post

    let body: PostParameter

    init(title: String? = nil, body: String? = nil) {
        self.body = PostParameter(title: title, body: body)
    }
}

@APIDefinition(method: .delete, path: "/posts/{postId}", auth: .anonymous)
struct DeletePost {
    typealias APIResponse = EmptyResponse

    let postId: Int
}

// MARK: - 3. Usage Examples

@MainActor
class BasicRequestExample {
    let client: DefaultNetworkClient

    init() {
        self.client = DefaultNetworkClient(
            baseURL: URL(string: "https://jsonplaceholder.typicode.com")!
        )
    }

    func getAllTodos() async {
        print("=== GET: Fetch all todos ===")
        do {
            let todos = try await client.request(GetTodos())
            print("Success! Fetched \(todos.count) todos")
            print("First todo: \(todos.first?.title ?? "N/A")")
        } catch {
            print("Error: \(error)")
        }
    }

    func getSinglePost() async {
        print("\n=== GET: Fetch single post ===")
        do {
            let post = try await client.request(GetPost(postId: 1))
            print("Success! Post #\(post.id ?? 0): \(post.title)")
        } catch {
            print("Error: \(error)")
        }
    }

    func createNewPost() async {
        print("\n=== POST: Create new post ===")
        do {
            let newPost = try await client.request(
                CreatePost(
                    title: "My New Post",
                    body: "This is the content of my new post",
                    userId: 1
                ))
            print("Success! Created post #\(newPost.id ?? 0)")
            print("Title: \(newPost.title)")
        } catch {
            print("Error: \(error)")
        }
    }

    func updatePost() async {
        print("\n=== PUT: Update post ===")
        do {
            let updatedPost = try await client.request(
                UpdatePost(
                    id: 1,
                    title: "Updated Title",
                    body: "Updated body content",
                    userId: 1
                ))
            print("Success! Updated post #\(updatedPost.id ?? 0)")
            print("New title: \(updatedPost.title)")
        } catch {
            print("Error: \(error)")
        }
    }

    func patchPost() async {
        print("\n=== PATCH: Partially update post ===")
        do {
            let patchedPost = try await client.request(PatchPost(title: "Patched Title"))
            print("Success! Patched post #\(patchedPost.id ?? 0)")
            print("New title: \(patchedPost.title)")
        } catch {
            print("Error: \(error)")
        }
    }

    func deletePost() async {
        print("\n=== DELETE: Delete post ===")
        do {
            _ = try await client.request(DeletePost(postId: 1))
            print("Success! Deleted post #1")
        } catch {
            print("Error: \(error)")
        }
    }

    func runAllExamples() async {
        await getAllTodos()
        await getSinglePost()
        await createNewPost()
        await updatePost()
        await patchPost()
        await deletePost()
    }
}

// MARK: - 5. Running the Examples

@main
struct BasicRequestApp {
    static func main() async {
        let example = BasicRequestExample()
        await example.runAllExamples()
    }
}
