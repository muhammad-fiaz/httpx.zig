const std = @import("std");
const httpx = @import("httpx");

const cert =
    \\-----BEGIN CERTIFICATE-----
    \\MIIDGjCCAgKgAwIBAgIUF2ynt8EnHkZmDJ2Ori/tSI5VFC0wDQYJKoZIhvcNAQEL
    \\BQAwFDESMBAGA1UEAwwJMTI3LjAuMC4xMB4XDTI2MDgzMDIxNTMzM1oXDTM2MDgy
    \\NzIxNTMzM1owFDESMBAGA1UEAwwJMTI3LjAuMC4xMIIBIjANBgkqhkiG9w0BAQEF
    \\AAOCAQ8AMIIBCgKCAQEAo/S6JY2+KY17DaElEHGGOEBbiGeXoqxANA/Qt3gsdHEk
    \\Vlk8wqL0W+/bzgB9iYHaqVZ+Z0D1Ley6/+nqxrw2hVkAt83Na9sOsmUVHTT9xjWC
    \\wp7E1DV2EqwAjl+3kOOKu4meQdbDaRS0P9lAUzOMrWJQpXBG4cMiNAyTRownXSFy
    \\9dQvq85JJeeV/+akclRzliXOZ6nlVnzSmk56eRwkVbA8iTX1BOLcKJ3+euP7uo3R
    \\+pXfVTZIFePgVK4a7zbMR/j8lotRkTu44lXo3zBAlN/qHKAXpdeZqI3LhASd6bm0
    \\kf3tkdyoOgmatlH53WXEIB+QmCvRs9jk7daHYGtazwIDAQABo2QwYjAdBgNVHQ4E
    \\FgQU8sm3Nw+TMraXDsP3vXV/w6ah3fYwHwYDVR0jBBgwFoAU8sm3Nw+TMraXDsP3
    \\vXV/w6ah3fYwDwYDVR0TAQH/BAUwAwEB/zAPBgNVHREECDAGhwR/AAABMA0GCSqG
    \\SIb3DQEBCwUAA4IBAQBnD8hgxaqVBfV2u6EI31fzmNEn34NRAimt3Ce5PqnxbAxR
    \\iy4fUK1peI7gJfMa8BfQ4LLXCn6lFc4nNLSDzfgCJLR3TSLl5fnxnnVufTsrUwAf
    \\xxCRkUl3pvodoriiJFsCmxmtSNDtkZhnqka6oQpOUu9N1M8tVL7XcKosBtYDFnh6
    \\c9MFuHwF3qUNcBriAQ9GenAiID2oRi6dBk05gWLQJn++R6jY/GOwAeATmlc+KqOZ
    \\eivaBnubzKzTBhAuURkf0Kdcl5jyH4xCsPriG/oAapuC2+fW/a+CeJqVNp26fXgp
    \\oKd0+wWE9hdoE0Wq9xAkUdbQRFBoOG2ZKW7ydO/L
    \\-----END CERTIFICATE-----
;

const key =
    \\-----BEGIN PRIVATE KEY-----
    \\MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCj9Loljb4pjXsN
    \\oSUQcYY4QFuIZ5eirEA0D9C3eCx0cSRWWTzCovRb79vOAH2JgdqpVn5nQPUt7Lr/
    \\6erGvDaFWQC3zc1r2w6yZRUdNP3GNYLCnsTUNXYSrACOX7eQ44q7iZ5B1sNpFLQ/
    \\2UBTM4ytYlClcEbhwyI0DJNGjCddIXL11C+rzkkl55X/5qRyVHOWJc5nqeVWfNKa
    \\Tnp5HCRVsDyJNfUE4twonf564/u6jdH6ld9VNkgV4+BUrhrvNsxH+PyWi1GRO7ji
    \\VejfMECU3+ocoBel15mojcuEBJ3pubSR/e2R3Kg6CZq2UfndZcQgH5CYK9Gz2OTt
    \\1odga1rPAgMBAAECggEACh2h1IpTxsWLZ5JfMo4GjXbvDtHxaaB+D5hANOmtuHt4
    \\lflIheu+7uM0KRgfprnDz3neL6my1uQJv5tjmGJpbL3KjQyeFX78/6W78ULhO3b2
    \\u+JG2572y30gRaiDL2XSm/KIOKCzCsszudLCJMAD+Hid6C8uuGQtOo/iEFK6ZQT/
    \\hYo6mbZPkaAt2kmH63BiqLEcEtJTtF2po2TgCh0NhrU+FjFMSgf1aIFpkVqTvA6e
    \\AqU9hTnUfcm76m4EdlSHpyC6ZzlM491ArVtp/hCX9+1V6DRybwnFI8h/4AH5xorA
    \\a5+WIojNatpFqBqzVgYfQSHa8tCRwFAZwgL8JFepvQKBgQDQPfgPUFVmLM0eJ0jI
    \\FRENu4XF3YwA73snCgPs8qojOuLiqAAY90UemMeC9HdeDxwe0xf3sU7TPszKME+b
    \\O6yU69cjlIHugWWkfEjkR13mVbf9bHNn/WyWS/GbCvzyIc1QBH+LC80Jokc5GxQV
    \\yTF8/TCk02Vc5CEE1wj8ClMCIwKBgQDJjrEIttYYUSdqrfO6z6XXTaUlENF5PEeY
    \\8kvrEZEEojVabAczPnH+/x5+pGSiD7UPGPpFDvkrfIJCi3HItYjjRbIh8iHx0Z+p
    \\LHaZcJAog6PFt6eQot2IR+YAIk18U+9e7QfBIpIrvGeXjj2DzLJQPLnMKlt8w7LO
    \\UrY8ZdchZQKBgBLaGVPhlOmcErGxIsCiT5nrqQ+hn+QRyhddq79OtKJd2V5lkSSx
    \\dftwH1e2o/vK6GPN/nR5A8bR/54qQ3qtK1GMDDz3W8/ovPfoHH02DMUma3Kw173J
    \\ToRIucWsd/u/naOp1JYU6mn92+7KicXzIdzL2xSA4sNHD8otYW3XzW37AoGAPHOX
    \\lU2BGPn+IHjbyQPOcazQAzXwHbR+pNjG/FHgdMtRxTTxU+U+u4Q42TLlG9YqL8UG
    \\CwBaqzhEuUCpd9E6pS+aJaRBmg2NHWhAifTAx+XzkLFsiGzQlLc7vH6NTuS9vnLJ
    \\CJwdyxBO4Z2/xW/3aylLcHijx9/KGSelkKfaxiECgYEAr1ur2S1LiYuyATEeuWvm
    \\/20I03cra7etMUqQl/e62OWqUUVK8oREyYuTpAqFn/QzHZb7T2Io6LO0Z+9IG70w
    \\FXzbaDWcKT0Sz9eAu6/CCs4GsM8DyuMSMV6NkAR8Xum1JYaVVUN0Fh5t3QTRNh74
    \\Ihtbl8l4ysfZvOPF0m5cXVw=
    \\-----END PRIVATE KEY-----
;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tls_listener = try httpx.tls.Listener.init(allocator, .{
        .port = 8448,
        .default_identity = .{
            .cert_chain_pem = cert,
            .private_key_pem = key,
        },
    });
    defer tls_listener.deinit();

    std.debug.print("TLS listener initialized on port {d}, config verified\n", .{tls_listener.localPort()});
}

fn runServer(listener: *httpx.tls.Listener) void {
    listener.run(handleRequest) catch |err| std.debug.print("TLS server error: {s}\n", .{@errorName(err)});
}

fn handleRequest(_: httpx.tls.Request) anyerror!httpx.tls.Response {
    return .{
        .status = 200,
        .body = "Hello from mTLS server!",
    };
}
