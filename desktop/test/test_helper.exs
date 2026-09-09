ExUnit.start(exclude: if(System.get_env("FOUNTAIN_CHECKOUT"), do: [], else: [:fountain_deployed]))
