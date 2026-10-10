"use client";

import { useEffect, useRef } from "react";

type GetTaggedModalLinkProps = {
  className?: string;
  children: React.ReactNode;
};

const CLOSE_MESSAGE = "tooltag:get-tagged-close";

export function GetTaggedModalLink({
  className,
  children,
}: GetTaggedModalLinkProps) {
  const dialogRef = useRef<HTMLDialogElement>(null);
  const frameRef = useRef<HTMLIFrameElement>(null);

  useEffect(() => {
    const onMessage = (event: MessageEvent) => {
      if (
        event.origin === window.location.origin &&
        event.data?.type === CLOSE_MESSAGE
      ) {
        dialogRef.current?.close();
      }
    };
    window.addEventListener("message", onMessage);
    return () => window.removeEventListener("message", onMessage);
  }, []);

  function open(event: React.MouseEvent<HTMLAnchorElement>) {
    if (!window.matchMedia("(min-width: 1024px)").matches) return;
    event.preventDefault();
    const frame = frameRef.current;
    if (frame && !frame.src) frame.src = "/get-tagged/modal";
    dialogRef.current?.showModal();
  }

  return (
    <>
      <a href="/get-tagged" className={className} onClick={open}>
        {children}
      </a>
      <dialog
        ref={dialogRef}
        className="get-tagged-react-dialog"
        aria-labelledby="get-tagged-react-dialog-title"
        onClick={(event) => {
          if (event.target === event.currentTarget) event.currentTarget.close();
        }}
      >
        <div className="get-tagged-react-dialog-shell">
          <div className="get-tagged-react-dialog-head">
            <div>
              <p className="eyebrow">GET TAGGED</p>
              <h2 id="get-tagged-react-dialog-title">Start your request.</h2>
            </div>
            <button
              type="button"
              className="close"
              aria-label="Close Get Tagged form"
              onClick={() => dialogRef.current?.close()}
            >
              ×
            </button>
          </div>
          <iframe
            ref={frameRef}
            title="Get Tagged request form"
            className="get-tagged-react-frame"
          />
        </div>
      </dialog>
    </>
  );
}
