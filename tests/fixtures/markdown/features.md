---
title: Markdown scopes
enabled: true
---

# Heading one
## Heading two
### Heading three
#### Heading four
##### Heading five
###### Heading six

Setext one
==========

Setext two
----------

A paragraph with **bold**, *italic*, ***both***, __strong__, _emphasis_,
~~struck text~~, `inline code`, ``a ` backtick``, and escaped \*markers\*.
Unicode αβ and 😀 preserve byte offsets. An entity &amp; and <https://example.com>.

[inline link](https://example.com "Link title") and ![image alt](image.png "Image title").
[reference link][target], [target][], [target], and <person@example.com>.

[target]: https://example.com "Reference title"

> A quote with **bold**.
>
> - A quoted list item
>   with a continuation.
>   > Nested quote with `code`.

- An unordered item
  with *emphasis* on a continuation.
  1. A nested numbered item
  2. Another item
- [x] A checked task
- [ ] An open task

1. An ordered item
2. Another ordered item

| Name | Value |
| :--- | ---: |
| **cell** | `42` |

---

    indented code
    another line

```css
:root { --fill: #ff00ff; color: var(--fill); }
```

```js
const answer = 42;
```

~~~unregistered
plain fenced content
~~~

<div class="card">
  <span title="αβ">HTML &amp; text</span>
</div>

<!-- a comment -->

After the blocks, **scopes must close**.
