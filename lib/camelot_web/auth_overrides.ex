defmodule CamelotWeb.AuthOverrides do
  @moduledoc """
  Custom overrides for AshAuthentication.Phoenix components
  using daisyUI theme classes.
  """
  use AshAuthentication.Phoenix.Overrides

  alias AshAuthentication.Phoenix.Components
  alias AshAuthentication.Phoenix.MagicSignInLive
  alias AshAuthentication.Phoenix.SignInLive

  override SignInLive do
    set(:root_class, "grid h-screen place-items-center bg-base-200")
  end

  override MagicSignInLive do
    set(:root_class, "grid h-screen place-items-center bg-base-200")
  end

  override Components.Banner do
    set(:image_url, nil)
    set(:dark_image_url, nil)
    set(:text, "Camelot")
    set(:text_class, "text-3xl font-bold text-base-content")
    set(:root_class, "w-full flex justify-center py-4")
  end

  override Components.SignIn do
    set(:root_class, """
    flex-1 flex flex-col justify-center py-12 px-4
    sm:px-6 lg:flex-none lg:px-20 xl:px-24
    """)

    set(:strategy_class, "card bg-base-100 shadow-xl p-8 mx-auto w-full max-w-sm lg:w-96")
    set(:authentication_error_container_class, "text-error text-center")
  end

  override Components.MagicLink do
    set(:label_class, "text-2xl tracking-tight font-bold text-base-content mb-4")
  end

  override Components.MagicLink.Input do
    set(:submit_class, "btn btn-primary w-full mt-4 mb-4")
    set(:field_class, "mt-2 mb-2")
    set(:label_class, "label text-sm font-medium")

    set(:input_class, """
    input input-bordered w-full
    """)

    set(:input_class_with_error, """
    input input-bordered input-error w-full
    """)

    set(:error_ul, "text-error font-light my-3 italic text-sm")
  end

  override Components.Password.Input do
    set(:field_class, "mt-2 mb-2")
    set(:label_class, "label text-sm font-medium")

    set(:input_class, """
    input input-bordered w-full
    """)

    set(:input_class_with_error, """
    input input-bordered input-error w-full
    """)

    set(:submit_class, "btn btn-primary w-full mt-4 mb-4")
    set(:error_ul, "text-error font-light my-3 italic text-sm")
  end

  override Components.Flash do
    set(:message_class_info, """
    fixed top-2 right-2 mr-2 w-80 sm:w-96 z-50 rounded-lg p-3
    text-sm alert alert-info
    """)

    set(:message_class_error, """
    fixed top-2 right-2 mr-2 w-80 sm:w-96 z-50 rounded-lg p-3
    text-sm alert alert-error
    """)
  end
end
