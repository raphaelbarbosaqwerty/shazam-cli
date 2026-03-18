defmodule Shazam.CLI.HttpClient do
  @moduledoc """
  HTTP helpers for communicating with the Shazam server via `:httpc`.
  Centralises `:inets`/`:ssl` bootstrapping and JSON encoding/decoding.
  """

  @doc "Perform an HTTP GET and JSON-decode the response body."
  def get(port, path) do
    ensure_http_started()
    url = ~c"http://127.0.0.1:#{port}#{path}"

    case :httpc.request(:get, {url, []}, [{:timeout, 5000}], []) do
      {:ok, {{_, 200, _}, _, body}} ->
        Jason.decode(to_string(body))

      {:ok, {{_, code, _}, _, body}} ->
        {:error, "HTTP #{code}: #{body}"}

      {:error, {:failed_connect, _}} ->
        {:error, "Cannot connect to localhost:#{port}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  @doc "Perform an HTTP POST with a JSON body and decode the response."
  def post(port, path, body) do
    ensure_http_started()
    url = ~c"http://127.0.0.1:#{port}#{path}"
    json = Jason.encode!(body)

    case :httpc.request(:post, {url, [], ~c"application/json", json}, [{:timeout, 10_000}], []) do
      {:ok, {{_, code, _}, _, resp}} when code in 200..299 ->
        Jason.decode(to_string(resp))

      {:ok, {{_, code, _}, _, resp}} ->
        {:error, "HTTP #{code}: #{resp}"}

      {:error, {:failed_connect, _}} ->
        {:error, "Cannot connect to localhost:#{port}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  @doc "Perform an HTTP PUT with a JSON body and decode the response."
  def put(port, path, body) do
    ensure_http_started()
    url = ~c"http://127.0.0.1:#{port}#{path}"
    json = Jason.encode!(body)

    case :httpc.request(:put, {url, [], ~c"application/json", json}, [{:timeout, 10_000}], []) do
      {:ok, {{_, code, _}, _, resp}} when code in 200..299 ->
        Jason.decode(to_string(resp))

      {:ok, {{_, code, _}, _, resp}} ->
        {:error, "HTTP #{code}: #{resp}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp ensure_http_started do
    :inets.start()
    :ssl.start()
  end
end
