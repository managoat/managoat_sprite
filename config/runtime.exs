import Config

# Sprite Services start with a minimal environment; erlexec needs a shell even
# though our execution API supplies explicit argument vectors.
if is_nil(System.get_env("SHELL")), do: System.put_env("SHELL", "/bin/sh")
