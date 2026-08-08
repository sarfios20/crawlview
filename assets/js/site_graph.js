const SVG_NS = "http://www.w3.org/2000/svg"
const NODE_EVENT = "site_graph:node"
const RESET_EVENT = "site_graph:reset"
const BROKEN_OUTCOMES = new Set([
  "not_found",
  "client_error",
  "server_error",
  "timeout",
  "unreachable",
])

const RING_SPACING = 52
const COMFORTABLE_NODE_COUNT = 160

// The ramp has six steps and a crawl may go deeper, so anything past the last step
// wears it. Depth beyond five is rare and the exact figure still shows in the table.
const RAMP_STEPS = 6
const depthColor = depth => `var(--depth-${Math.min(depth, RAMP_STEPS - 1)})`

const el = (tag, className, text) => {
  const node = document.createElement(tag)
  if (className) node.className = className
  if (text !== undefined) node.textContent = text
  return node
}

const svgEl = (tag, attributes = {}) => {
  const node = document.createElementNS(SVG_NS, tag)
  for (const [name, value] of Object.entries(attributes)) node.setAttribute(name, value)
  return node
}

const SiteGraph = {
  mounted() {
    this.nodes = new Map()
    this.swept = false

    this.svg = svgEl("svg", {
      role: "img",
      "aria-label": "Radial plot of crawled pages by link depth",
      "aria-describedby": "site-graph-description",
      class: "plot__svg",
    })

    // The key is built here rather than server-side because this hook already holds
    // every node: the per-depth tally is a property of the picture, so computing it
    // here keeps the server from mirroring crawl state it does not own.
    this.key = el("div", "plot__key")

    this.warning = el("p", "plot__warning")
    this.warning.setAttribute("role", "status")
    this.warning.hidden = true

    const figure = el("div", "plot__figure")
    figure.append(this.svg, this.key)
    this.el.replaceChildren(figure, this.warning)

    this.handleEvent(NODE_EVENT, node => {
      const isNew = !this.nodes.has(node.url)
      this.nodes.set(node.url, node)
      this.render(isNew ? node.url : null)
    })

    this.handleEvent(RESET_EVENT, () => {
      this.nodes.clear()
      this.swept = false
      this.render(null)
    })

    this.render(null)
  },

  render(newUrl) {
    const nodes = [...this.nodes.values()]
    const tree = this.buildTree(nodes)
    const positions = this.layout(tree)
    const maximumDepth = nodes.reduce((maximum, node) => Math.max(maximum, node.depth), 0)

    // The frame follows the tree instead of the tree sitting inside a fixed frame. A
    // constant viewBox sized for the deepest crawl allowed would leave a shallow site
    // as a small blob in a large empty box, so the radius comes from the depth
    // actually reached, plus room for the outermost node and its focus ring.
    const viewRadius = Math.max(maximumDepth, 1) * RING_SPACING + 26
    this.svg.setAttribute(
      "viewBox",
      `${-viewRadius} ${-viewRadius} ${viewRadius * 2} ${viewRadius * 2}`
    )

    this.svg.replaceChildren(
      this.drawRings(maximumDepth),
      this.drawEdges(nodes, positions),
      this.drawNodes(nodes, positions, newUrl)
    )

    this.drawKey(nodes, maximumDepth)

    if (nodes.length > COMFORTABLE_NODE_COUNT) {
      this.warning.textContent = `${nodes.length} pages plotted. The picture is getting dense; the table below stays readable.`
      this.warning.hidden = false
    } else {
      this.warning.textContent = ""
      this.warning.hidden = true
    }
  },

  buildTree(nodes) {
    const byUrl = this.nodes
    const children = new Map(nodes.map(node => [node.url, []]))
    const roots = []

    for (const node of nodes) {
      const parent = node.referrer && byUrl.get(node.referrer)

      // A referrer can arrive after its child. Until then that child is a top-level
      // subtree with an edge to the centre; rebuilding this index on every event
      // attaches it to its real parent as soon as that parent exists, so a node is
      // never dropped and the picture never breaks.
      if (parent && parent.url !== node.url) {
        children.get(parent.url).push(node)
      } else {
        roots.push(node)
      }
    }

    for (const siblings of children.values()) {
      siblings.sort((left, right) => left.url.localeCompare(right.url))
    }
    roots.sort((left, right) => left.url.localeCompare(right.url))

    return {children, roots}
  },

  layout({children, roots}) {
    const weights = new Map()
    const subtreeWeight = node => {
      const childNodes = children.get(node.url)
      const weight = Math.max(1, childNodes.reduce((sum, child) => sum + subtreeWeight(child), 0))
      weights.set(node.url, weight)
      return weight
    }
    roots.forEach(subtreeWeight)

    const positions = new Map()

    // Radius is depth: each click from the front page adds one 52-unit ring. Angle is
    // position within the parent's slice, divided in proportion to subtree size, so
    // siblings fan out and a branch stays visually together. Recomputing every angle
    // on each arrival is simpler to read than incremental geometry and easily fast
    // enough at the page cap this crawler enforces.
    const positionSubtree = (node, sliceStart, sliceEnd) => {
      const angle = (sliceStart + sliceEnd) / 2
      const radius = node.depth * RING_SPACING
      positions.set(node.url, {
        x: Math.cos(angle) * radius,
        y: Math.sin(angle) * radius,
      })

      const childNodes = children.get(node.url)
      const totalWeight = childNodes.reduce((sum, child) => sum + weights.get(child.url), 0)
      let cursor = sliceStart

      for (const child of childNodes) {
        const width = (sliceEnd - sliceStart) * (weights.get(child.url) / totalWeight)
        positionSubtree(child, cursor, cursor + width)
        cursor += width
      }
    }

    const totalRootWeight = roots.reduce((sum, root) => sum + weights.get(root.url), 0)
    let rootCursor = -Math.PI / 2

    for (const root of roots) {
      const width = Math.PI * 2 * (weights.get(root.url) / totalRootWeight)
      positionSubtree(root, rootCursor, rootCursor + width)
      rootCursor += width
    }

    return positions
  },

  drawRings(maximumDepth) {
    const sweep =
      !this.swept &&
      maximumDepth > 0 &&
      !window.matchMedia("(prefers-reduced-motion: reduce)").matches

    if (maximumDepth > 0) this.swept = true

    const layer = svgEl("g", {
      "aria-hidden": "true",
      class: sweep ? "plot__rings--sweep" : "",
    })

    for (let depth = 1; depth <= maximumDepth; depth += 1) {
      layer.append(
        svgEl("circle", {
          r: depth * RING_SPACING,
          fill: "none",
          stroke: "var(--plot-ring)",
          "stroke-width": "1",
          "stroke-dasharray": "2 6",
        })
      )
    }

    // Range rings carry their own number, the way a contour carries its elevation.
    // It means the reader learns the scale from the picture and not from prose.
    for (let depth = 1; depth <= maximumDepth; depth += 1) {
      const label = svgEl("text", {
        x: 0,
        y: -depth * RING_SPACING + 4,
        "text-anchor": "middle",
        fill: "var(--color-base-content)",
        "fill-opacity": "0.4",
        "font-size": "10",
        "font-family": "var(--font-data)",
      })
      label.textContent = depth
      layer.append(label)
    }

    return layer
  },

  drawEdges(nodes, positions) {
    const layer = svgEl("g", {
      "aria-hidden": "true",
      fill: "none",
      stroke: "var(--plot-edge)",
      "stroke-width": "1",
    })

    for (const node of nodes) {
      if (node.depth === 0) continue

      const point = positions.get(node.url)
      const parentPoint = node.referrer && positions.get(node.referrer)
      layer.append(
        svgEl("line", {
          x1: parentPoint ? parentPoint.x : 0,
          y1: parentPoint ? parentPoint.y : 0,
          x2: point.x,
          y2: point.y,
        })
      )
    }

    return layer
  },

  drawNodes(nodes, positions, newUrl) {
    const layer = svgEl("g")
    const stillMoving = !window.matchMedia("(prefers-reduced-motion: reduce)").matches

    for (const node of nodes) {
      const point = positions.get(node.url)
      const broken = BROKEN_OUTCOMES.has(node.outcome)

      const group = svgEl("g", {
        transform: `translate(${point.x} ${point.y})`,
        tabindex: "0",
        "aria-label": `${node.url}, depth ${node.depth}, ${node.outcome}`,
      })

      const title = svgEl("title")
      title.textContent = node.url
      group.append(title)

      const visual = svgEl("g")

      if (broken) {
        // Broken pages carry an outer ring as well as the reserved colour, so they
        // stay identifiable in greyscale, in forced colours and to a colour-blind
        // reader. The gap is painted in the surface so the ring reads as a halo.
        visual.append(
          svgEl("circle", {
            r: "9.5",
            fill: "none",
            stroke: "var(--plot-surface)",
            "stroke-width": "3",
          }),
          svgEl("circle", {
            r: "9.5",
            fill: "none",
            stroke: "var(--broken)",
            "stroke-width": "1.75",
          }),
          svgEl("circle", {r: "5", fill: "var(--broken)"})
        )
      } else {
        visual.append(
          svgEl("circle", {
            r: node.depth === 0 ? "8" : "5",
            fill: depthColor(node.depth),
            stroke: "var(--plot-surface)",
            "stroke-width": "1.5",
          })
        )
      }

      group.append(visual)
      layer.append(group)

      if (node.url === newUrl && stillMoving) {
        visual.animate(
          [
            {opacity: 0, transform: "scale(0.3)"},
            {opacity: 1, transform: "scale(1)"},
          ],
          {duration: 240, easing: "cubic-bezier(0.2, 0.8, 0.2, 1)"}
        )
      }
    }

    return layer
  },

  // The key is legend, tally and distribution in one column: it names what the
  // colours mean, counts what has been found, and shows where the site's weight
  // sits. It is the thing that lets a stranger read the plot unaided.
  drawKey(nodes, maximumDepth) {
    const counts = new Array(maximumDepth + 1).fill(0)
    let brokenCount = 0

    for (const node of nodes) {
      counts[node.depth] = (counts[node.depth] || 0) + 1
      if (BROKEN_OUTCOMES.has(node.outcome)) brokenCount += 1
    }

    const busiest = Math.max(1, ...counts)
    const rows = el("div", "key__rows")

    counts.forEach((count, depth) => {
      const row = el("div", "key__row")
      row.style.color = depthColor(depth)

      const dot = el("span", "key__dot")
      dot.style.background = depthColor(depth)

      const bar = el("span", "key__bar")
      bar.style.width = `${(count / busiest) * 100}%`

      row.append(
        dot,
        el("span", "key__depth", `${depth}`),
        bar,
        el("span", "key__count", `${count}`)
      )
      rows.append(row)
    })

    const depths = el("div")
    depths.append(el("p", "key__heading", "Clicks from front page"), rows)

    const broken = el("div", "key__broken")
    broken.append(
      el("span", "key__broken-mark"),
      el("span", "key__broken-label", "Broken"),
      el("span", "key__broken-count", `${brokenCount}`)
    )

    this.key.replaceChildren(depths, broken)
  },
}

export default SiteGraph
