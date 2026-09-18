import type { FeatureExtractionPipeline } from '@huggingface/transformers';

const MODEL = 'Xenova/all-MiniLM-L6-v2';

export class Embedder {
  private extractor: FeatureExtractionPipeline | null = null;

  async init(): Promise<void> {
    // Deferred on purpose. `@huggingface/transformers` is ~37 MB of module
    // graph, and importing it at the top of this file pays that at server
    // startup whether or not the process ever embeds. `import type` above keeps
    // the type without loading the module; the dynamic import here pulls the
    // runtime only when a turn first calls init(). The cast sidesteps the
    // pipeline overload union, which is too large for the checker to represent.
    const { pipeline } = await import('@huggingface/transformers');
    const build = pipeline as unknown as (
      task: 'feature-extraction', model: string, options?: { dtype?: string },
    ) => Promise<FeatureExtractionPipeline>;
    this.extractor = await build('feature-extraction', MODEL, { dtype: 'q8' });
  }

  async embed(text: string): Promise<Float32Array> {
    if (!this.extractor) throw new Error('Embedder not initialized. Call init() first.');
    const output = await this.extractor(text, {
      pooling: 'mean',
      normalize: true,
    });
    return new Float32Array(output.tolist()[0] as number[]);
  }

  async dispose(): Promise<void> {
    if (this.extractor) {
      await this.extractor.dispose();
      this.extractor = null;
    }
  }

  static buildEmbeddingText(
    title: string,
    tags: string[],
    content: string,
  ): string {
    const firstParagraph = content.split(/\n\n+/)[0] ?? '';
    const parts = [title];
    if (tags.length > 0) {
      parts.push(tags.join(', '));
    }
    if (firstParagraph) {
      parts.push(firstParagraph);
    }
    return parts.join('\n');
  }
}
