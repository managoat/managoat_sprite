defmodule ManaspritesDesktop.Vault do
  @moduledoc "Encrypted local credentials; the browser receives presence flags only."
  use GenServer
  import Ecto.Query
  alias ManaspritesDesktop.Repo
  @providers ~w(sprites openai anthropic github)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_) do
    root = Application.fetch_env!(:manasprites_desktop, :root)
    path = Path.join(root, "vault.key")

    key =
      case File.read(path) do
        {:ok, key} when byte_size(key) == 32 ->
          key

        {:error, :enoent} ->
          if Repo.aggregate(ManaspritesDesktop.Credential, :count, :name) > 0,
            do: raise("Local vault key is missing; restore it before opening this workspace.")

          key = :crypto.strong_rand_bytes(32)
          File.write!(path, key, [:write, :exclusive, :sync])
          File.chmod!(path, 0o600)
          key

        _ ->
          raise "Local vault key is unreadable; restore it before opening this workspace."
      end

    File.chmod!(path, 0o600)
    {:ok, key}
  end

  def providers, do: @providers
  def presence, do: Map.new(@providers, &{&1, present?(&1)})

  def present?(name),
    do: Repo.exists?(from(c in ManaspritesDesktop.Credential, where: c.name == ^name))

  def put(name, value), do: GenServer.call(__MODULE__, {:put, name, value})
  def seal(name, value), do: GenServer.call(__MODULE__, {:seal, name, value})
  def get(name), do: GenServer.call(__MODULE__, {:get, name})

  def delete(name),
    do: Repo.delete_all(from(c in ManaspritesDesktop.Credential, where: c.name == ^name))

  @impl true
  def handle_call({:seal, name, value}, _, key) do
    if is_binary(value) and byte_size(value) in 1..16384 and
         not String.contains?(value, ["\r", "\n", <<0>>]) do
      iv = :crypto.strong_rand_bytes(12)
      {cipher, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, value, name, 16, true)
      {:reply, {:ok, iv <> tag <> cipher}, key}
    else
      {:reply, {:error, :invalid_credential}, key}
    end
  end

  def handle_call({:put, name, value}, _, key) do
    if is_binary(value) and byte_size(value) in 1..16384 and
         not String.contains?(value, ["\r", "\n", <<0>>]) do
      iv = :crypto.strong_rand_bytes(12)
      {cipher, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, value, name, 16, true)

      Repo.insert_all(
        ManaspritesDesktop.Credential,
        [%{name: name, ciphertext: iv <> tag <> cipher}],
        on_conflict: {:replace, [:ciphertext]},
        conflict_target: :name,
        log: false
      )

      {:reply, :ok, key}
    else
      {:reply, {:error, :invalid_credential}, key}
    end
  end

  def handle_call({:get, name}, _, key) do
    reply =
      case Repo.one(
             from(c in ManaspritesDesktop.Credential,
               where: c.name == ^name,
               select: c.ciphertext
             )
           ) do
        <<iv::binary-size(12), tag::binary-size(16), cipher::binary>> ->
          case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, cipher, name, tag, false) do
            value when is_binary(value) -> {:ok, value}
            _ -> {:error, :vault_corrupt}
          end

        nil ->
          {:error, :credential_missing}

        _ ->
          {:error, :vault_corrupt}
      end

    {:reply, reply, key}
  end

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: :redacted, message: :redacted, reason: :redacted})
end
