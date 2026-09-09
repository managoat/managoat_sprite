defmodule ManaspritesDesktop.Fountain.Accounts do
  @moduledoc "Operator-provisioned identities and revocable, account-scoped bearer keys."
  alias ManaspritesDesktop.Fountain.Store
  alias ManaspritesDesktop.Vault

  def import(email, key, credentials, verified?) do
    if not (is_binary(email) and String.contains?(email, "@") and verified? == true and
              is_binary(key) and byte_size(key) in 24..512),
       do:
         raise(
           ArgumentError,
           "An operator-verified email and a key of at least 24 bytes are required"
         )

    {:ok, account} =
      Store.transaction(fn ->
        existing = Store.list("local", "account") |> Enum.find(&(&1["email"] == email))

        account =
          existing ||
            %{"id" => Store.id(), "email" => email, "email_verified" => true, "role" => "user"}

        Store.put("local", "account", account)

        account_id = account["id"]

        case authenticate(key) do
          nil -> mint(account["id"], "Operator key", key)
          %{"id" => ^account_id} -> :ok
          _ -> Store.abort("key_already_owned")
        end

        account
      end)

    for {name, value} <- credentials do
      true = name in ~w(sprites openai anthropic)
      :ok = Vault.put("fountain:#{account["id"]}:#{name}", value)
    end

    account
  end

  def credential(owner, name), do: Vault.get("fountain:#{owner}:#{name}")

  def authenticate(key) when is_binary(key) and byte_size(key) <= 512 do
    hash = Store.digest(key)

    case Store.query(
           "SELECT owner FROM fountain_objects WHERE kind='key' AND json_extract(record,'$._digest')=?",
           [hash]
         ).rows do
      [[owner]] -> Store.get("local", "account", owner)
      _ -> nil
    end
  end

  def authenticate(_), do: nil

  def mint(owner, name, raw \\ nil) do
    key = raw || "msp_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    record = %{
      "id" => Store.id(),
      "name" => name,
      "prefix" => String.slice(key, 0, 8),
      "created_at" => Store.now(),
      "scopes" => ["*"],
      "_digest" => Store.digest(key)
    }

    Store.put(owner, "key", record)
    record |> Store.public() |> Map.put("key", key)
  end
end
